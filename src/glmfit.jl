"""
    GlmResp

The response vector and various derived vectors in a generalized linear model.
"""
struct GlmResp{V<:FPVector,D<:UnivariateDistribution,L<:Link} <: ModResp
    "`y`: response vector"
    y::V
    d::D
    "`devresid`: the squared deviance residuals"
    devresid::V
    "`eta`: the linear predictor"
    eta::V
    "`mu`: mean response"
    mu::V
    "`offset:` offset added to `Xβ` to form `eta`.  Can be of length 0"
    offset::V
    "`wts:` prior case weights.  Can be of length 0."
    wts::V
    "`wrkwt`: working case weights for the Iteratively Reweighted Least Squares (IRLS) algorithm"
    wrkwt::V
    "`wrkresid`: working residuals for IRLS"
    wrkresid::V
end

function GlmResp(y::V, d::D, l::L, η::V, μ::V, off::V, wts::V) where {V<:FPVector, D, L}
    if d == Binomial()
        for yy in y
            0 ≤ yy ≤ 1 || throw(ArgumentError("$yy in y is not in [0,1]"))
        end
    else
        all(x -> insupport(d, x), y) || throw(ArgumentError("y must be in the support of D"))
    end
    n = length(y)
    nη = length(η)
    nμ = length(μ)
    length(wts) == nη == nμ == n || throw(DimensionMismatch(
        "lengths of η, μ, y and wts ($nη, $nμ, $(length(wts)), $n) are not equal"))
    lo = length(off)
    lo == 0 || lo == n || error("offset must have length $n or length 0")
    res = GlmResp{V,D,L}(y, d, similar(y), η, μ, off, wts, similar(y), similar(y))
    updateμ!(res, η)
    res
end

deviance(r::GlmResp) = sum(r.devresid)

"""
    cancancel(r::GlmResp{V,D,L})

Returns `true` if dμ/dη for link `L` is the variance function for distribution `D`

When `L` is the canonical link for `D` the derivative of the inverse link is a multiple
of the variance function for `D`.  If they are the same a numerator and denominator term in
the expression for the working weights will cancel.
"""
cancancel(::GlmResp) = false
cancancel(::GlmResp{V,D,LogitLink}) where {V,D<:Union{Bernoulli,Binomial}} = true
cancancel(::GlmResp{V,D,IdentityLink}) where {V,D<:Normal} = true
cancancel(::GlmResp{V,D,LogLink}) where {V,D<:Poisson} = true

"""
    updateμ!{T<:FPVector}(r::GlmResp{T}, linPr::T)

Update the mean, working weights and working residuals, in `r` given a value of
the linear predictor, `linPr`.
"""
function updateμ! end

function updateμ!(r::GlmResp{T}, linPr::T) where T<:FPVector
    isempty(r.offset) ? copy!(r.eta, linPr) : broadcast!(+, r.eta, linPr, r.offset)
    updateμ!(r)
    if !isempty(r.wts)
        map!(*, r.devresid, r.devresid, r.wts)
        map!(*, r.wrkwt, r.wrkwt, r.wts)
    end
    r
end

function updateμ!(r::GlmResp{V,D,L}) where {V<:FPVector,D,L}
    y, η, μ, wrkres, wrkwt, dres = r.y, r.eta, r.mu, r.wrkresid, r.wrkwt, r.devresid

    @inbounds for i in eachindex(y, η, μ, wrkres, wrkwt, dres)
        μi, dμdη = inverselink(L(), η[i])
        μ[i] = μi
        yi = y[i]
        wrkres[i] = (yi - μi) / dμdη
        wrkwt[i] = cancancel(r) ? dμdη : abs2(dμdη) / glmvar(r.d, μi)
        dres[i] = devresid(r.d, yi, μi)
    end
end

function updateμ!(r::GlmResp{V,D,L}) where {V<:FPVector,D<:Union{Bernoulli,Binomial},L<:Link01}
    y, η, μ, wrkres, wrkwt, dres = r.y, r.eta, r.mu, r.wrkresid, r.wrkwt, r.devresid

    @inbounds for i in eachindex(y, η, μ, wrkres, wrkwt, dres)
        μi, dμdη, μomμ = inverselink(L(), η[i])
        μ[i] = μi
        yi = y[i]
        wrkres[i] = (yi - μi) / dμdη
        wrkwt[i] = cancancel(r) ? dμdη : abs2(dμdη) / μomμ
        dres[i] = devresid(r.d, yi, μi)
    end
end

"""
    wrkresp(r::GlmResp)

The working response, `r.eta + r.wrkresid - r.offset`.
"""
wrkresp(r::GlmResp) = wrkresp!(similar(r.eta), r)

"""
    wrkresp!{T<:FPVector}(v::T, r::GlmResp{T})

Overwrite `v` with the working response of `r`
"""
function wrkresp!(v::T, r::GlmResp{T}) where T<:FPVector
    broadcast!(+, v, r.eta, r.wrkresid)
    isempty(r.offset) ? v : broadcast!(-, v, v, r.offset)
end

abstract type AbstractGLM <: LinPredModel end

mutable struct GeneralizedLinearModel{G<:GlmResp,L<:LinPred} <: AbstractGLM
    rr::G
    pp::L
    fit::Bool
end

function coeftable(mm::AbstractGLM)
    cc = coef(mm)
    se = stderr(mm)
    zz = cc ./ se
    CoefTable(hcat(cc,se,zz,2.0 * ccdf.(Normal(), abs.(zz))),
              ["Estimate","Std.Error","z value", "Pr(>|z|)"],
              ["x$i" for i = 1:size(mm.pp.X, 2)], 4)
end

function confint(obj::AbstractGLM, level::Real)
    hcat(coef(obj),coef(obj)) + stderr(obj)*quantile(Normal(),(1. -level)/2.)*[1. -1.]
end
confint(obj::AbstractGLM) = confint(obj, 0.95)

deviance(m::AbstractGLM) = deviance(m.rr)

function loglikelihood(m::AbstractGLM)
    r = m.rr
    wts = r.wts
    y = r.y
    mu = r.mu
    ϕ = deviance(m)/sum(wts)
    d = r.d
    ll = zero(loglik_obs(d, y[1], mu[1], wts[1], ϕ))
    @inbounds for i in eachindex(y, mu, wts)
        ll += loglik_obs(d, y[i], mu[i], wts[i], ϕ)
    end
    ll
end

dof(x::GeneralizedLinearModel) = dispersion_parameter(x.rr.d) ? length(coef(x)) + 1 : length(coef(x))

function _fit!(m::AbstractGLM, verbose::Bool, maxIter::Integer, minStepFac::Real,
              convTol::Real, start)
    m.fit && return m
    maxIter >= 1 || throw(ArgumentError("maxIter must be positive"))
    0 < minStepFac < 1 || throw(ArgumentError("minStepFac must be in (0, 1)"))

    cvg, p, r = false, m.pp, m.rr
    lp = r.mu
    if start == nothing || isempty(start)
        delbeta!(p, wrkresp(r), r.wrkwt)
        linpred!(lp, p)
        updateμ!(r, lp)
        installbeta!(p)
    else
        copy!(p.beta0, start)
        fill!(p.delbeta, 0)
        linpred!(lp, p, 0)
        updateμ!(r, lp)
    end
    devold = deviance(m)
    for i = 1:maxIter
        f = 1.0
        local dev
        try
            delbeta!(p, r.wrkresid, r.wrkwt)
            linpred!(lp, p)
            updateμ!(r, lp)
            dev = deviance(m)
        catch e
            isa(e, DomainError) ? (dev = Inf) : rethrow(e)
        end
        while dev > devold
            f /= 2.
            f > minStepFac || error("step-halving failed at beta0 = $(p.beta0)")
            try
                updateμ!(r, linpred(p, f))
                dev = deviance(m)
            catch e
                isa(e, DomainError) ? (dev = Inf) : rethrow(e)
            end
        end
        installbeta!(p, f)
        crit = (devold - dev)/dev
        verbose && println("$i: $dev, $crit")
        if crit < convTol || dev == 0
            cvg = true
            break
        end
        @assert isfinite(crit)
        devold = dev
    end
    cvg || throw(ConvergenceException(maxIter))
    m.fit = true
    m
end

StatsBase.fit!(m::AbstractGLM; verbose::Bool=false, maxIter::Integer=30,
              minStepFac::Real=0.001, convTol::Real=1.e-6, start=nothing) =
    _fit!(m, verbose, maxIter, minStepFac, convTol, start)

function initialeta!(dist::UnivariateDistribution, link::Link,
                     eta::AbstractVector, y::AbstractVector, wts::AbstractVector,
                     off::AbstractVector)
    length(eta) == length(y) == length(wts) || throw(DimensionMismatch("argument lengths do not match"))
    @inbounds @simd for i = eachindex(y, eta, wts)
        μ = mustart(dist, y[i], wts[i])
        eta[i] = linkfun(link, μ)
    end
    if !isempty(off)
        @inbounds @simd for i = eachindex(eta,off)
            eta[i] -= off[i]
        end
    end
    eta
end

function StatsBase.fit!(m::AbstractGLM, y; wts=nothing, offset=nothing, dofit::Bool=true,
                        verbose::Bool=false, maxIter::Integer=30, minStepFac::Real=0.001, convTol::Real=1.e-6,
                        start=nothing)
    r = m.rr
    V = typeof(r.y)
    r.y = copy!(r.y, y)
    isa(wts, Void) || copy!(r.wts, wts)
    isa(offset, Void) || copy!(r.offset, offset)
    initialeta!(r.d, r.l, r.eta, r.y, r.wts, r.offset)
    updateμ!(r, r.eta)
    fill!(m.pp.beta0, 0)
    m.fit = false
    if dofit
        _fit!(m, verbose, maxIter, minStepFac, convTol, start)
    else
        m
    end
end

function fit(::Type{M},
    X::Union{Matrix{T},SparseMatrixCSC{T}}, y::V,
    d::UnivariateDistribution,
    l::Link = canonicallink(d);
    dofit::Bool = true,
    wts::V = ones(y),
    offset::V = similar(y, 0), fitargs...) where {M<:AbstractGLM,T<:FP,V<:FPVector}

    size(X, 1) == size(y, 1) || throw(DimensionMismatch("number of rows in X and y must match"))
    n = length(y)
    length(wts) == n || throw(DimensionMismatch("length(wts) does not match length(y)"))
    if length(offset) != n && length(offset) != 0
        throw(DimensionMismatch("length(offset) does not match length(y)"))
    end

    wts = T <: Float64 ? copy(wts) : convert(typeof(y), wts)
    off = T <: Float64 ? copy(offset) : convert(Vector{T}, offset)
    eta = initialeta!(d, l, similar(y), y, wts, off)
    rr = GlmResp(y, d, l, eta, similar(y), offset, wts)
    res = M(rr, cholpred(X), false)
    dofit ? fit!(res; fitargs...) : res
end

fit(::Type{M},
X::Union{Matrix,SparseMatrixCSC},
y::AbstractVector,
d::UnivariateDistribution,
l::Link=canonicallink(d); kwargs...) where {M<:AbstractGLM} =
    fit(M, float(X), float(y), d, l; kwargs...)

glm(X, y, args...; kwargs...) = fit(GeneralizedLinearModel, X, y, args...; kwargs...)

GLM.Link(mm::AbstractGLM) = mm.l
GLM.Link(r::GlmResp{T,D,L}) where {T,D,L} = L()
GLM.Link(m::GeneralizedLinearModel) = Link(m.rr)

Distributions.Distribution(r::GlmResp{T,D,L}) where {T,D,L} = D
Distributions.Distribution(m::GeneralizedLinearModel) = Distribution(m.rr)

"""
    dispersion(m::AbstractGLM, sqr::Bool=false)

Return the estimated dispersion (or scale) parameter for a model's distribution,
generally written σ² for linear models and ϕ for generalized linear models.
It is, by definition, equal to 1 for the Bernoulli, Binomial, and Poisson families.

If `sqr` is `true`, the squared dispersion parameter is returned.
"""
function dispersion(m::AbstractGLM, sqr::Bool=false)
    r = m.rr
    if dispersion_parameter(r.d)
        wrkwt, wrkresid = r.wrkwt, r.wrkresid
        s = sum(i -> wrkwt[i] * abs2(wrkresid[i]), eachindex(wrkwt, wrkresid)) / dof_residual(m)
        sqr ? s : sqrt(s)
    else
        one(eltype(r.mu))
    end
end

"""
    predict(mm::AbstractGLM, newX::AbstractMatrix; offset::FPVector=Vector{eltype(newX)}(0))

Form the predicted response of model `mm` from covariate values `newX` and, optionally,
an offset.
"""
function predict(mm::AbstractGLM, newX::AbstractMatrix;
                 offset::FPVector=eltype(newX)[])
    eta = newX * coef(mm)
    if !isempty(mm.rr.offset)
        length(offset) == size(newX, 1) ||
            throw(ArgumentError("fit with offset, so `offset` kw arg must be an offset of length `size(newX, 1)`"))
        broadcast!(+, eta, eta, offset)
    else
        length(offset) > 0 && throw(ArgumentError("fit without offset, so value of `offset` kw arg does not make sense"))
    end
    mu = [linkinv(Link(mm), x) for x in eta]
end
