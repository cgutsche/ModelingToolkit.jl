"""
$(TYPEDEF)

A scalar equation for optimization.

# Fields
$(FIELDS)

# Examples

```julia
@variables x y z
@parameters a b c

obj = a * (y - x) + x * (b - z) - y + x * y - c * z
@named os = OptimizationSystem(obj, [x, y, z], [a, b, c])
```
"""
struct OptimizationSystem <: AbstractOptimizationSystem
    """
    tag: a tag for the system. If two system have the same tag, then they are
    structurally identical.
    """
    tag::UInt
    """Objective function of the system."""
    op::Any
    """Unknown variables."""
    states::Vector
    """Parameters."""
    ps::Vector
    """Array variables."""
    var_to_name::Any
    """Observed variables."""
    observed::Vector{Equation}
    """List of constraint equations of the system."""
    constraints::Vector{Union{Equation, Inequality}}
    """The unique name of the system."""
    name::Symbol
    """The internal systems."""
    systems::Vector{OptimizationSystem}
    """
    The default values to use when initial guess and/or
    parameters are not supplied in `OptimizationProblem`.
    """
    defaults::Dict
    """
    metadata: metadata for the system, to be used by downstream packages.
    """
    metadata::Any
    """
    complete: if a model `sys` is complete, then `sys.x` no longer performs namespacing.
    """
    complete::Bool

    function OptimizationSystem(tag, op, states, ps, var_to_name, observed,
                                constraints, name, systems, defaults, metadata = nothing,
                                complete = false; checks::Union{Bool, Int} = true)
        if checks == true || (checks & CheckUnits) > 0
            unwrap(op) isa Symbolic && check_units(op)
            check_units(observed)
            all_dimensionless([states; ps]) || check_units(constraints)
        end
        new(tag, op, states, ps, var_to_name, observed,
            constraints, name, systems, defaults, metadata, complete)
    end
end

equations(sys::AbstractOptimizationSystem) = objective(sys) # needed for Base.show

function OptimizationSystem(op, states, ps;
                            observed = [],
                            constraints = [],
                            default_u0 = Dict(),
                            default_p = Dict(),
                            defaults = _merge(Dict(default_u0), Dict(default_p)),
                            name = nothing,
                            systems = OptimizationSystem[],
                            checks = true,
                            metadata = nothing)
    name === nothing &&
        throw(ArgumentError("The `name` keyword must be provided. Please consider using the `@named` macro"))

    constraints = value.(scalarize(constraints))
    states′ = value.(scalarize(states))
    ps′ = value.(scalarize(ps))
    op′ = value(scalarize(op))

    if !(isempty(default_u0) && isempty(default_p))
        Base.depwarn("`default_u0` and `default_p` are deprecated. Use `defaults` instead.",
                     :OptimizationSystem, force = true)
    end
    sysnames = nameof.(systems)
    if length(unique(sysnames)) != length(sysnames)
        throw(ArgumentError("System names must be unique."))
    end
    defaults = todict(defaults)
    defaults = Dict(value(k) => value(v) for (k, v) in pairs(defaults))

    var_to_name = Dict()
    process_variables!(var_to_name, defaults, states′)
    process_variables!(var_to_name, defaults, ps′)
    isempty(observed) || collect_var_to_name!(var_to_name, (eq.lhs for eq in observed))

    OptimizationSystem(Threads.atomic_add!(SYSTEM_COUNT, UInt(1)),
                       op′, states′, ps′, var_to_name,
                       observed,
                       constraints,
                       name, systems, defaults, metadata; checks = checks)
end

function calculate_gradient(sys::OptimizationSystem)
    expand_derivatives.(gradient(objective(sys), states(sys)))
end

function generate_gradient(sys::OptimizationSystem, vs = states(sys), ps = parameters(sys);
                           kwargs...)
    grad = calculate_gradient(sys)
    pre = get_preprocess_constants(grad)
    return build_function(grad, vs, ps; postprocess_fbody = pre,
                          conv = AbstractSysToExpr(sys), kwargs...)
end

function calculate_hessian(sys::OptimizationSystem)
    expand_derivatives.(hessian(objective(sys), states(sys)))
end

function generate_hessian(sys::OptimizationSystem, vs = states(sys), ps = parameters(sys);
                          sparse = false, kwargs...)
    if sparse
        hess = sparsehessian(objective(sys), states(sys))
    else
        hess = calculate_hessian(sys)
    end
    pre = get_preprocess_constants(hess)
    return build_function(hess, vs, ps; postprocess_fbody = pre,
                          conv = AbstractSysToExpr(sys), kwargs...)
end

function generate_function(sys::OptimizationSystem, vs = states(sys), ps = parameters(sys);
                           kwargs...)
    eqs = subs_constants(objective(sys))
    return build_function(eqs, vs, ps;
                          conv = AbstractSysToExpr(sys), kwargs...)
end

function objective(sys)
    op = get_op(sys)
    systems = get_systems(sys)
    if isempty(systems)
        op
    else
        op + reduce(+, map(sys_ -> namespace_expr(get_op(sys_), sys_), systems))
    end
end

namespace_constraint(eq::Equation, sys) = namespace_equation(eq, sys)

namespace_constraint(ineq::Inequality, sys) = namespace_inequality(ineq, sys)

function namespace_inequality(ineq::Inequality, sys, n = nameof(sys))
    _lhs = namespace_expr(ineq.lhs, sys, n)
    _rhs = namespace_expr(ineq.rhs, sys, n)
    Inequality(_lhs,
               _rhs,
               ineq.relational_op)
end

function namespace_constraints(sys)
    namespace_constraint.(get_constraints(sys), Ref(sys))
end

function constraints(sys)
    cs = get_constraints(sys)
    systems = get_systems(sys)
    isempty(systems) ? cs : [cs; reduce(vcat, namespace_constraints.(systems))]
end

hessian_sparsity(sys::OptimizationSystem) = hessian_sparsity(get_op(sys), states(sys))

function rep_pars_vals!(e::Expr, p)
    rep_pars_vals!.(e.args, Ref(p))
    replace!(e.args, p...)
end

function rep_pars_vals!(e, p) end

"""
```julia
function DiffEqBase.OptimizationProblem{iip}(sys::OptimizationSystem,u0map,
                                          parammap=DiffEqBase.NullParameters();
                                          lb=nothing, ub=nothing,
                                          grad = false,
                                          hess = false, sparse = false,
                                          checkbounds = false,
                                          linenumbers = true, parallel=SerialForm(),
                                          kwargs...) where iip
```

Generates an OptimizationProblem from an OptimizationSystem and allows for automatically
symbolically calculating numerical enhancements.
"""
function DiffEqBase.OptimizationProblem(sys::OptimizationSystem, args...; kwargs...)
    DiffEqBase.OptimizationProblem{true}(sys::OptimizationSystem, args...; kwargs...)
end
function DiffEqBase.OptimizationProblem{iip}(sys::OptimizationSystem, u0map,
                                             parammap = DiffEqBase.NullParameters();
                                             lb = nothing, ub = nothing,
                                             grad = false,
                                             hess = false, sparse = false,
                                             checkbounds = false,
                                             linenumbers = true, parallel = SerialForm(),
                                             use_union = false,
                                             kwargs...) where {iip}
    if !(isnothing(lb) && isnothing(ub))
        Base.depwarn("`lb` and `ub` are deprecated. Use the `bounds` metadata for the variables instead.",
                     :OptimizationProblem, force = true)
    end

    if haskey(kwargs, :lcons) || haskey(kwargs, :ucons)
        Base.depwarn("`lcons` and `ucons` are deprecated. Specify constraints directly instead.",
                     :OptimizationProblem, force = true)
    end

    dvs = states(sys)
    ps = parameters(sys)
    cstr = constraints(sys)

    lb = first.(getbounds.(dvs))
    ub = last.(getbounds.(dvs))
    int = isintegervar.(dvs) .| isbinaryvar.(dvs)
    lb[isbinaryvar.(dvs)] .= 0
    ub[isbinaryvar.(dvs)] .= 1

    defs = defaults(sys)
    defs = mergedefaults(defs, parammap, ps)
    defs = mergedefaults(defs, u0map, dvs)

    u0 = varmap_to_vars(u0map, dvs; defaults = defs, tofloat = false)
    p = varmap_to_vars(parammap, ps; defaults = defs, tofloat = false, use_union)
    lb = varmap_to_vars(dvs .=> lb, dvs; defaults = defs, tofloat = false, use_union)
    ub = varmap_to_vars(dvs .=> ub, dvs; defaults = defs, tofloat = false, use_union)

    if all(lb .== -Inf) && all(ub .== Inf)
        lb = nothing
        ub = nothing
    end

    f = generate_function(sys, checkbounds = checkbounds, linenumbers = linenumbers,
                          expression = Val{false})

    obj_expr = toexpr(subs_constants(objective(sys)))
    pairs_arr = if p isa SciMLBase.NullParameters
        [Symbol(_s) => Expr(:ref, :x, i) for (i, _s) in enumerate(dvs)]
    else
        vcat([Symbol(_s) => Expr(:ref, :x, i) for (i, _s) in enumerate(dvs)],
             [Symbol(_p) => p[i] for (i, _p) in enumerate(ps)])
    end
    rep_pars_vals!(obj_expr, pairs_arr)
    if grad
        grad_oop, grad_iip = generate_gradient(sys, checkbounds = checkbounds,
                                               linenumbers = linenumbers,
                                               parallel = parallel, expression = Val{false})
        _grad(u, p) = grad_oop(u, p)
        _grad(J, u, p) = (grad_iip(J, u, p); J)
    else
        _grad = nothing
    end

    if hess
        hess_oop, hess_iip = generate_hessian(sys, checkbounds = checkbounds,
                                              linenumbers = linenumbers,
                                              sparse = sparse, parallel = parallel,
                                              expression = Val{false})
        _hess(u, p) = hess_oop(u, p)
        _hess(J, u, p) = (hess_iip(J, u, p); J)
    else
        _hess = nothing
    end

    if sparse
        hess_prototype = hessian_sparsity(sys)
    else
        hess_prototype = nothing
    end

    if length(cstr) > 0
        @named cons_sys = ConstraintsSystem(cstr, dvs, ps)
        cons, lcons, ucons = generate_function(cons_sys, checkbounds = checkbounds,
                                               linenumbers = linenumbers,
                                               expression = Val{false})
        cons_j = generate_jacobian(cons_sys; expression = Val{false}, sparse = sparse)[2]
        cons_h = generate_hessian(cons_sys; expression = Val{false}, sparse = sparse)[2]

        cons_expr = toexpr.(subs_constants(constraints(cons_sys)))
        rep_pars_vals!.(cons_expr, Ref(pairs_arr))

        if sparse
            cons_jac_prototype = jacobian_sparsity(cons_sys)
            cons_hess_prototype = hessian_sparsity(cons_sys)
        else
            cons_jac_prototype = nothing
            cons_hess_prototype = nothing
        end
        _f = DiffEqBase.OptimizationFunction{iip}(f,
                                                  sys = sys,
                                                  SciMLBase.NoAD();
                                                  grad = _grad,
                                                  hess = _hess,
                                                  hess_prototype = hess_prototype,
                                                  syms = Symbol.(states(sys)),
                                                  paramsyms = Symbol.(parameters(sys)),
                                                  cons = cons[2],
                                                  cons_j = cons_j,
                                                  cons_h = cons_h,
                                                  cons_jac_prototype = cons_jac_prototype,
                                                  cons_hess_prototype = cons_hess_prototype,
                                                  expr = obj_expr,
                                                  cons_expr = cons_expr)
        OptimizationProblem{iip}(_f, u0, p; lb = lb, ub = ub, int = int,
                                 lcons = lcons, ucons = ucons, kwargs...)
    else
        _f = DiffEqBase.OptimizationFunction{iip}(f,
                                                  sys = sys,
                                                  SciMLBase.NoAD();
                                                  grad = _grad,
                                                  hess = _hess,
                                                  syms = Symbol.(states(sys)),
                                                  paramsyms = Symbol.(parameters(sys)),
                                                  hess_prototype = hess_prototype,
                                                  expr = obj_expr)
        OptimizationProblem{iip}(_f, u0, p; lb = lb, ub = ub, int = int,
                                 kwargs...)
    end
end

"""
```julia
function DiffEqBase.OptimizationProblemExpr{iip}(sys::OptimizationSystem,
                                          parammap=DiffEqBase.NullParameters();
                                          u0=nothing, lb=nothing, ub=nothing,
                                          grad = false,
                                          hes = false, sparse = false,
                                          checkbounds = false,
                                          linenumbers = true, parallel=SerialForm(),
                                          kwargs...) where iip
```

Generates a Julia expression for an OptimizationProblem from an
OptimizationSystem and allows for automatically symbolically
calculating numerical enhancements.
"""
struct OptimizationProblemExpr{iip} end

function OptimizationProblemExpr(sys::OptimizationSystem, args...; kwargs...)
    OptimizationProblemExpr{true}(sys::OptimizationSystem, args...; kwargs...)
end

function OptimizationProblemExpr{iip}(sys::OptimizationSystem, u0,
                                      parammap = DiffEqBase.NullParameters();
                                      lb = nothing, ub = nothing,
                                      grad = false,
                                      hess = false, sparse = false,
                                      checkbounds = false,
                                      linenumbers = false, parallel = SerialForm(),
                                      use_union = false,
                                      kwargs...) where {iip}
    if !(isnothing(lb) && isnothing(ub))
        Base.depwarn("`lb` and `ub` are deprecated. Use the `bounds` metadata for the variables instead.",
                     :OptimizationProblem, force = true)
    end

    if haskey(kwargs, :lcons) || haskey(kwargs, :ucons)
        Base.depwarn("`lcons` and `ucons` are deprecated. Specify constraints directly instead.",
                     :OptimizationProblem, force = true)
    end

    dvs = states(sys)
    ps = parameters(sys)
    cstr = constraints(sys)

    idx = iip ? 2 : 1
    f = generate_function(sys, checkbounds = checkbounds, linenumbers = linenumbers,
                          expression = Val{true})
    if grad
        _grad = generate_gradient(sys, checkbounds = checkbounds, linenumbers = linenumbers,
                                  parallel = parallel, expression = Val{false})[idx]
    else
        _grad = :nothing
    end

    if hess
        _hess = generate_hessian(sys, checkbounds = checkbounds, linenumbers = linenumbers,
                                 sparse = sparse, parallel = parallel,
                                 expression = Val{false})[idx]
    else
        _hess = :nothing
    end

    if sparse
        hess_prototype = hessian_sparsity(sys)
    else
        hess_prototype = nothing
    end

    lb = first.(getbounds.(dvs))
    ub = last.(getbounds.(dvs))
    int = isintegervar.(dvs) .| isbinaryvar.(dvs)
    lb[isbinaryvar.(dvs)] .= 0
    ub[isbinaryvar.(dvs)] .= 1

    defs = defaults(sys)
    defs = mergedefaults(defs, parammap, ps)
    defs = mergedefaults(defs, u0map, dvs)

    u0 = varmap_to_vars(u0map, dvs; defaults = defs, tofloat = false)
    p = varmap_to_vars(parammap, ps; defaults = defs, tofloat = false, use_union)
    lb = varmap_to_vars(dvs .=> lb, dvs; defaults = defs, tofloat = false, use_union)
    ub = varmap_to_vars(dvs .=> ub, dvs; defaults = defs, tofloat = false, use_union)

    if all(lb .== -Inf) && all(ub .== Inf)
        lb = nothing
        ub = nothing
    end

    obj_expr = toexpr(subs_constants(objective(sys)))
    pairs_arr = if p isa SciMLBase.NullParameters
        [Symbol(_s) => Expr(:ref, :x, i) for (i, _s) in enumerate(dvs)]
    else
        vcat([Symbol(_s) => Expr(:ref, :x, i) for (i, _s) in enumerate(dvs)],
             [Symbol(_p) => p[i] for (i, _p) in enumerate(ps)])
    end
    rep_pars_vals!(obj_expr, pairs_arr)

    if length(cstr) > 0
        @named cons_sys = ConstraintsSystem(cstr, dvs, ps)
        cons, lcons, ucons = generate_function(cons_sys, checkbounds = checkbounds,
                                               linenumbers = linenumbers,
                                               expression = Val{false})
        cons_j = generate_jacobian(cons_sys; expression = Val{false}, sparse = sparse)[2]
        cons_h = generate_hessian(cons_sys; expression = Val{false}, sparse = sparse)[2]

        cons_expr = toexpr.(subs_constants(constraints(cons_sys)))
        rep_pars_vals!.(cons_expr, Ref(pairs_arr))

        if sparse
            cons_jac_prototype = jacobian_sparsity(cons_sys)
            cons_hess_prototype = hessian_sparsity(cons_sys)
        else
            cons_jac_prototype = nothing
            cons_hess_prototype = nothing
        end

        quote
            f = $f
            p = $p
            u0 = $u0
            grad = $_grad
            hess = $_hess
            lb = $lb
            ub = $ub
            int = $int
            cons = $cons[1]
            lbcons = $lbcons
            ubcons = $ubcons
            cons_j = $cons_j
            cons_h = $cons_h
            syms = $(Symbol.(states(sys)))
            paramsyms = $(Symbol.(parameters(sys)))
            _f = OptimizationFunction{iip}(f, SciMLBase.NoAD();
                                           grad = grad,
                                           hess = hess,
                                           syms = syms,
                                           paramsyms = paramsyms,
                                           hess_prototype = hess_prototype,
                                           cons = cons,
                                           cons_j = cons_j,
                                           cons_h = cons_h,
                                           cons_jac_prototype = cons_jac_prototype,
                                           cons_hess_prototype = cons_hess_prototype,
                                           expr = obj_expr,
                                           cons_expr = cons_expr)
            OptimizationProblem{$iip}(_f, u0, p; lb = lb, ub = ub, int = int, lcons = lcons,
                                      ucons = ucons, kwargs...)
        end
    else
        quote
            f = $f
            p = $p
            u0 = $u0
            grad = $_grad
            hess = $_hess
            lb = $lb
            ub = $ub
            int = $int
            syms = $(Symbol.(states(sys)))
            paramsyms = $(Symbol.(parameters(sys)))
            _f = OptimizationFunction{iip}(f, SciMLBase.NoAD();
                                           grad = grad,
                                           hess = hess,
                                           syms = syms,
                                           paramsyms = paramsyms,
                                           hess_prototype = hess_prototype,
                                           expr = obj_expr)
            OptimizationProblem{$iip}(_f, u0, p; lb = lb, ub = ub, int = int, kwargs...)
        end
    end
end
