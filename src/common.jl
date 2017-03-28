## Common Interface Solve Functions

function solve{uType,tType,isinplace,F,Method,LinearSolver}(
    prob::AbstractODEProblem{uType,tType,isinplace,F},
    alg::SundialsODEAlgorithm{Method,LinearSolver},
    timeseries=[],ts=[],ks=[];
    callback=()->nothing,abstol=1/10^6,reltol=1/10^3,
    saveat=Float64[],adaptive=true,maxiter=Int(1e5),
    timeseries_errors=true,save_timeseries=true,
    userdata=nothing,kwargs...)

    tspan = prob.tspan
    t0 = tspan[1]

    tdir = sign(tspan[2]-tspan[1])

    if !isempty(saveat) && saveat[1] == tspan[1]
      save_ts = @view saveat[2:end]
    else
      save_ts = saveat
    end

    if !isempty(save_ts) && save_ts[end] != tspan[2]
      push!(save_ts,tspan[2])
    elseif isempty(save_ts)
      save_ts = [tspan[2]]
    end


    if typeof(prob.u0) <: Number
        u0 = [prob.u0]
    else
        u0 = vec(deepcopy(prob.u0))
    end

    sizeu = size(prob.u0)

    ### Fix the more general function to Sundials allowed style
    if !isinplace && (typeof(prob.u0)<:Vector{Float64} || typeof(prob.u0)<:Number)
        f! = (t,u,du) -> (du[:] = prob.f(t,u); 0)
    elseif !isinplace && typeof(prob.u0)<:AbstractArray
        f! = (t,u,du) -> (du[:] = vec(prob.f(t,reshape(u,sizeu))); 0)
    elseif typeof(prob.u0)<:Vector{Float64}
        f! = prob.f
    else # Then it's an in-place function on an abstract array
        f! = (t,u,du) -> (prob.f(t,reshape(u,sizeu),reshape(du,sizeu));
                          u = vec(u); du=vec(du); 0)
    end

    if typeof(alg) <: CVODE_BDF
        alg_code = CV_BDF
    elseif typeof(alg) <:  CVODE_Adams
        alg_code = CV_ADAMS
    end

    if Method == :Newton
        method_code = CV_NEWTON
    elseif Method ==  :Functional
        method_code = CV_FUNCTIONAL
    end

    mem_ptr = CVodeCreate(alg_code, method_code)
    (mem_ptr == C_NULL) && error("Failed to allocate CVODE solver object")
    mem = Handle(mem_ptr)

    ures = Vector{Vector{Float64}}()
    ts   = [t0]

    userfun = UserFunctionAndData(f!, userdata)
    u0nv = NVector(u0)
    flag = @checkflag CVodeInit(mem,
                          cfunction(cvodefun, Cint,
                          (realtype, N_Vector,
                          N_Vector, Ref{typeof(userfun)})),
                          t0, convert(N_Vector, u0nv))
    flag = @checkflag CVodeSetUserData(mem, userfun)
    flag = @checkflag CVodeSStolerances(mem, reltol, abstol)
    flag = @checkflag CVodeSetMaxNumSteps(mem, maxiter)
    if Method == :Newton # Only use a linear solver if it's a Newton-based method
        if LinearSolver == :Dense
            flag = @checkflag CVDense(mem, length(u0))
        elseif LinearSolver == :Banded
            flag = @checkflag CVBand(mem,length(u0),alg.jac_upper,alg.jac_lower)
        elseif LinearSolver == :Diagonal
            flag = @checkflag CVDiag(mem)
        elseif LinearSolver == :GMRES
            flag = @checkflag CVSpgmr(mem,PREC_NONE,alg.krylov_dim)
        elseif LinearSolver == :BCG
            flag = @checkflag CVSpgmr(mem,PREC_NONE,alg.krylov_dim)
        elseif LinearSolver == :TFQMR
            flag = @checkflag CVSptfqmr(mem,PREC_NONE,alg.krylov_dim)
        end
    end

    push!(ures, copy(u0))
    utmp = NVector(copy(u0))
    tout = [tspan[1]]

    # The Inner Loops : Style depends on save_timeseries
    if save_timeseries
        for k in 1:length(save_ts)
            looped = false
            while tdir*tout[end] < tdir*save_ts[k]
                looped = true
                flag = @checkflag CVode(mem,
                                save_ts[k], utmp, tout, CV_ONE_STEP)
                push!(ures,copy(utmp))
                push!(ts, tout...)
                if flag != 0
                    break
                end
            end
            if flag != 0
                break
            end
            if looped
                # Fix the end
                flag = @checkflag CVodeGetDky(
                                        mem, save_ts[k], Cint(0), ures[end])
                ts[end] = save_ts[k]
            else # Just push another value
                flag = @checkflag CVodeGetDky(
                                        mem, save_ts[k], Cint(0), utmp)
                push!(ures,copy(utmp))
                push!(ts, save_ts[k]...)
            end
            if flag != 0
                break
            end
        end
    else # save_timeseries == false, so use CV_NORMAL style
        for k in 1:length(save_ts)
            flag = @checkflag CVode(mem,
                                save_ts[k], utmp, tout, CV_NORMAL)
            push!(ures,copy(utmp))
            push!(ts, save_ts[k]...)
            if flag != 0
                break
            end
        end
    end

    ### Finishing Routine

    timeseries = Vector{uType}(0)
    if typeof(prob.u0)<:Number
        for i=1:length(ures)
            push!(timeseries,ures[i][1])
        end
    else
        for i=1:length(ures)
            push!(timeseries,reshape(ures[i],sizeu))
        end
    end

    build_solution(prob,alg,ts,timeseries,
                      timeseries_errors = timeseries_errors)
end

## Solve for DAEs uses IDA

function solve{uType,duType,tType,isinplace,F,LinearSolver}(
    prob::AbstractDAEProblem{uType,duType,tType,isinplace,F},
    alg::SundialsDAEAlgorithm{LinearSolver},
    timeseries=[],ts=[],ks=[];
    callback=()->nothing,abstol=1/10^6,reltol=1/10^3,
    saveat=Float64[],adaptive=true,maxiter=Int(1e5),
    timeseries_errors=true,save_timeseries=true,
    userdata=nothing,kwargs...)

    tspan = prob.tspan
    t0 = tspan[1]

    tdir = sign(tspan[2]-tspan[1])

    if !isempty(saveat) && saveat[1] == tspan[1]
      save_ts = @view saveat[2:end]
    else
      save_ts = saveat
    end

    if !isempty(save_ts) && save_ts[end] != tspan[2]
      push!(save_ts,tspan[2])
    elseif isempty(save_ts)
      save_ts = [tspan[2]]
    end

    if typeof(prob.u0) <: Number
        u0 = [prob.u0]
    else
        u0 = vec(deepcopy(prob.u0))
    end

    if typeof(prob.du0) <: Number
        du0 = [prob.du0]
    else
        du0 = vec(deepcopy(prob.du0))
    end

    sizeu = size(prob.u0)
    sizedu = size(prob.du0)

    ### Fix the more general function to Sundials allowed style
    if !isinplace && (typeof(prob.u0)<:Vector{Float64} || typeof(prob.u0)<:Number)
        f! = (t,u,du,out) -> (out[:] = prob.f(t,u,du); 0)
    elseif !isinplace && typeof(prob.u0)<:AbstractArray
        f! = (t,u,du,out) -> (out[:] = vec(prob.f(t,reshape(u,sizeu),reshape(du,sizedu))); 0)
    elseif typeof(prob.u0)<:Vector{Float64}
        f! = prob.f
    else # Then it's an in-place function on an abstract array
        f! = (t,u,du,out) -> (prob.f(t,reshape(u,sizeu),reshape(du,sizedu),out);
                          u = vec(u); du=vec(du); 0)
    end

    mem_ptr = IDACreate()
    (mem_ptr == C_NULL) && error("Failed to allocate IDA solver object")
    mem = Handle(mem_ptr)

    ures = Vector{Vector{Float64}}()
    ts   = [t0]

    userfun = UserFunctionAndData(f!, userdata)
    u0nv = NVector(u0)
    flag = @checkflag IDAInit(mem, cfunction(idasolfun,
                              Cint, (realtype, N_Vector, N_Vector,
                              N_Vector, Ref{typeof(userfun)})),
                              t0, convert(N_Vector, u0),
                              convert(N_Vector, du0))
    flag = @checkflag IDASetUserData(mem, userfun)
    flag = @checkflag IDASStolerances(mem, reltol, abstol)
    flag = @checkflag IDASetMaxNumSteps(mem, maxiter)
    if LinearSolver == :Dense
        flag = @checkflag IDADense(mem, length(u0))
    elseif LinearSolver == :Band
        flag = @checkflag IDABand(mem,length(u0),alg.jac_upper,alg.jac_lower)
    elseif LinearSolver == :Diagonal
        flag = @checkflag IDADiag(mem)
    elseif LinearSolver == :GMRES
        flag = @checkflag IDASpgmr(mem,PREC_NONE,alg.krylov_dim)
    elseif LinearSolver == :BCG
        flag = @checkflag IDASpgmr(mem,PREC_NONE,alg.krylov_dim)
    elseif LinearSolver == :TFQMR
        flag = @checkflag IDASptfqmr(mem,PREC_NONE,alg.krylov_dim)
    end


    push!(ures, copy(u0))
    utmp = NVector(copy(u0))
    dutmp = NVector(copy(u0))
    tout = [tspan[1]]

    rtest = zeros(length(u0))
    f!(t0, u0, du0, rtest)
    if any(abs.(rtest) .>= reltol)
        if diffstates === nothing
            error("Must supply diffstates argument to use IDA initial value solver.")
        end
        flag = @checkflag IDASetId(mem, collect(Float64, diffstates))
        flag = @checkflag IDACalcIC(mem, IDA_YA_YDP_INIT, save_ts[2])
    end

    # The Inner Loops : Style depends on save_timeseries
    if save_timeseries
        for k in 1:length(save_ts)
            looped = false
            while tdir*tout[end] < tdir*save_ts[k]
                looped = true
                flag = @checkflag IDASolve(mem,
                                save_ts[k], tout, utmp, dutmp, IDA_ONE_STEP)

                push!(ures,copy(utmp))
                push!(ts, tout...)
            end
            if looped
                # Fix the end
                flag = @checkflag IDAGetDky(
                                        mem, save_ts[k], Cint(0), ures[end])
                ts[end] = save_ts[k]
            else # Just push another value
                flag = @checkflag IDAGetDky(
                                        mem, save_ts[k], Cint(0), utmp)
                push!(ures,copy(utmp))
                push!(ts, save_ts[k]...)
            end
        end
    else # save_timeseries == false, so use IDA_NORMAL style
        for k in 1:length(save_ts)
            flag = @checkflag IDASolve(mem,
                                save_ts[k], tout, utmp, dutmp, IDA_NORMAL)
            push!(ures,copy(utmp))
            push!(ts, save_ts[k]...)
        end
    end

    ### Finishing Routine

    timeseries = Vector{uType}(0)
    if typeof(prob.u0)<:Number
        for i=1:length(ures)
            push!(timeseries,ures[i][1])
        end
    else
        for i=1:length(ures)
            push!(timeseries,reshape(ures[i],sizeu))
        end
    end

    build_solution(prob,alg,ts,timeseries,
                      timeseries_errors = timeseries_errors)
end
