# This file is a part of JuliaFEM.
# License is MIT: see https://github.com/JuliaFEM/JuliaFEM.jl/blob/master/LICENSE.md

type Solver
    name :: ASCIIString # some descriptive name for problem
    time :: Real        # current time
    iteration :: Int    # iteration counter
    norms :: Vector{Tuple} # solution norms for convergence studies
    ndofs :: Int        # total dimension of global stiffness matrix, i.e., dim*nnodes
    problems :: Vector{Problem}
    is_linear_system :: Bool # setting this to true makes assumption of one step convergence
    nonlinear_system_min_iterations :: Int64
    nonlinear_system_max_iterations :: Int64
    nonlinear_system_convergence_tolerance :: Float64
    nonlinear_system_error_if_no_convergence :: Bool
    linear_system_solver :: Symbol
end

function Solver(name::ASCIIString="default solver", time::Real=0.0)
    return Solver(
        name,
        time,
        0,     # iteration #
        [],    # solution norms in (norm(u), norm(la)) tuples
        0,     # ndofs
        [],    # array of problems
        false, # is_linear_system
        1,     # min nonlinear iterations
        10,    # max nonlinear iterations
        5.0e-5, # nonlinear iteration convergence tolerance
        true,  # throw error if no convergence
        :DirectLinearSolver # linear system solution method
        )
end

function push!(solver::Solver, problem)
    push!(solver.problems, problem)
end

# one-liner helpers to identify problem types

function is_field_problem(problem)
    return false
end
function is_field_problem{P<:FieldProblem}(problem::Problem{P})
    return true
end

function is_boundary_problem(problem)
    return false
end
function is_boundary_problem{P<:BoundaryProblem}(problem::Problem{P})
    return true
end

function is_dirichlet_problem(problem)
    return false
end
function is_dirichlet_problem{P<:Problem{Dirichlet}}(problem::P)
    return true
end

#=
function is_mortar_problem{P<:Problem{Mortar}}(problem::P)
    return true
end
=#

function get_field_problems(solver::Solver)
    filter(is_field_problem, solver.problems)
end

function get_boundary_problems(solver::Solver)
    filter(is_boundary_problem, solver.problems)
end

function get_dirichlet_problems(solver::Solver)
    filter(is_dirichlet_problem, solver.problems)
end

function get_mortar_problems(solver::Solver)
    filter(is_mortar_problem, solver.problems)
end

""" Posthook for field assembly. By default, do nothing. """
function field_assembly_posthook!
end

"""Return one combined field assembly for a set of field problems.

Parameters
----------
solver :: Solver

Returns
-------
K, f :: SparseMatrixCSC

Notes
-----
If several field problems exists, they are simply summed together, so
problems must have unique node ids.

"""
function get_field_assembly(solver::Solver)
    problems = get_field_problems(solver)
    K = SparseMatrixCOO()
    f = SparseMatrixCOO()
    for problem in problems
        assembly = problem.assembly
        append!(K, assembly.K)
        append!(f, assembly.f)
    end
    K = sparse(K)
    solver.ndofs = size(K, 1)
    f = sparse(f, solver.ndofs, 1)

    # run any posthook for assembly if defined
    args = Tuple{Solver, SparseMatrixCSC, SparseMatrixCSC}
    if method_exists(field_assembly_posthook!, args)
        field_assembly_posthook!(solver, K, f)
    end

    return K, f
end

""" Posthook for boundary assembly. By default, do nothing. """
function boundary_assembly_posthook!
end

""" Return one combined boundary assembly for a set of boundary problems.

Returns
-------
C1, C2, D, g :: SparseMatrixCSC

Notes
-----
When some dof is constrained by multiple boundary problems an algorithm is
launched what tries to do it's best to solve issue. It's far from perfect
but is able to handle some basic situations occurring in corner nodes and
crosspoints.

"""
function get_boundary_assembly(solver::Solver)
    ndofs = solver.ndofs
    @assert ndofs != 0
    K = spzeros(ndofs, ndofs)
    C1 = spzeros(ndofs, ndofs)
    C2 = spzeros(ndofs, ndofs)
    D = spzeros(ndofs, ndofs)
    f = spzeros(ndofs, 1)
    g = spzeros(ndofs, 1)
    for problem in get_boundary_problems(solver)
        assembly = problem.assembly
        K_ = sparse(assembly.K, ndofs, ndofs)
        C1_ = sparse(assembly.C1, ndofs, ndofs)
        C2_ = sparse(assembly.C2, ndofs, ndofs)
        D_ = sparse(assembly.D, ndofs, ndofs)
        f_ = sparse(assembly.f, ndofs, 1)
        g_ = sparse(assembly.g, ndofs, 1)
        # check for overconstraint situation and handle it if possible
        already_constrained = get_nonzero_rows(C2)
        new_constraints = get_nonzero_rows(C2_)
        overconstrained_dofs = intersect(already_constrained, new_constraints)
        if length(overconstrained_dofs) != 0
            overconstrained_dofs = sort(overconstrained_dofs)
            overconstrained_nodes = find_nodes_by_dofs(problem, overconstrained_dofs)
            handle_overconstraint_error!(problem, overconstrained_nodes,
                overconstrained_dofs, C1, C1_, C2, C2_, D, D_, g, g_)
        end
        K += K_
        C1 += C1_
        C2 += C2_
        D += D_
        f += f_
        g += g_
    end
    return K, C1, C2, D, f, g
end


""" Solve linear system using LU factorization (UMFPACK).
"""
function solve_linear_system(solver::Solver, ::Type{Val{:DirectLinearSolver}})
    info("solving linear system of $(length(solver.problems)) problems.")
    t0 = time()

    # assemble field problems
    K, f = get_field_assembly(solver)

    # assemble boundary problems
    Kb, C1, C2, D, fb, g = get_boundary_assembly(solver)

    # construct global system Ax=b and solve using lu factorization
    A = [K+Kb C1'; C2 D]
    b = [f+fb; g]

    nz = get_nonzero_rows(A)
    x = zeros(length(b))
    x[nz] = lufact(A[nz,nz]) \ full(b[nz])

    ndofs = solver.ndofs
    u = x[1:ndofs]
    la = x[ndofs+1:end]
    info("UMFPACK: solved in ", time()-t0, " seconds. norm = ", norm(u))
    return u, la
end


""" Check convergence of problems.

Notes
-----
Default convergence criteria is obtained by checking each sub-problem convergence.
"""
function has_converged(solver::Solver; check_convergence_for_boundary_problems=false)
    converged = true
    eps = solver.nonlinear_system_convergence_tolerance
    for problem in solver.problems
        has_converged = true
        if is_field_problem(problem)
            has_converged = problem.assembly.u_norm_change < eps
            if isapprox(norm(problem.assembly.u), 0.0)
                has_converged = true
            end
            info("Details for problem $(problem.name)")
            info("Norm: $(norm(problem.assembly.u))")
            info("Norm change: $(problem.assembly.u_norm_change)")
            info("Has converged? $(has_converged)")
        end
        if is_boundary_problem(problem) && check_convergence_for_boundary_problems
            has_converged = problem.assembly.la_norm_change/norm(problem.assembly.la) < eps
            info("Details for problem $(problem.name)")
            info("Norm: $(norm(problem.assembly.la))")
            info("Norm change: $(problem.assembly.la_norm_change)")
            info("Has converged? $(has_converged)")
        end
        converged &= has_converged
    end
    return converged || solver.is_linear_system
end

type NonlinearConvergenceError <: Exception
    solver :: Solver
end

function Base.showerror(io::IO, exception::NonlinearConvergenceError)
    max_iters = exception.solver.nonlinear_system_max_iterations
    print(io, "nonlinear iteration did not converge in $max_iters iterations!")
end

""" Main solver loop.
"""
function call(solver::Solver)

    # 1. initialize each problem so that we can start nonlinear iterations
    for problem in solver.problems
        initialize!(problem, solver.time)
    end

    # 2. start non-linear iterations
    for solver.iteration=1:solver.nonlinear_system_max_iterations
        info("Starting nonlinear iteration #$(solver.iteration)")

        # 2.1 update linearized assemblies (if needed)
        for problem in solver.problems
            problem.assembly.changed = true  # force reassembly
            assemble!(problem, solver.time)
        end

        # 2.2 call solver for linearized system (default: direct lu factorization)
        u, la = solve_linear_system(solver, Val{solver.linear_system_solver})
        push!(solver.norms, (norm(u), norm(la)))

        # 2.3 update solution back to elements
        for problem in solver.problems
            u_new, la_new = update_assembly!(problem, u, la)
            update_elements!(problem, u_new, la_new)
        end

        # 2.4 check convergence
        if has_converged(solver)
            info("Converged in $(solver.iteration) iterations.")
            if solver.iteration < solver.nonlinear_system_min_iterations
                info("Converged but continuing")
            else
                return true
            end
        end
    end

    # 3. did not converge
    if solver.nonlinear_system_error_if_no_convergence
        throw(NonlinearConvergenceError(solver))
    end
end

