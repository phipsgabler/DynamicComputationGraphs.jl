abstract type AbstractTrackingContext end

"""Tracks everything down to calls of intrinsic functions."""
struct DefaultTrackingContext <: AbstractTrackingContext end

const DEFAULT_CTX = DefaultTrackingContext()



"""Tracks nested calls until a certain level."""
struct DepthLimitContext <: AbstractTrackingContext
    level::Int
    maxlevel::Int
end

DepthLimitContext(maxlevel) = DepthLimitContext(1, maxlevel)

increase_level(ctx::DepthLimitContext) = DepthLimitContext(ctx.level + 1, ctx.maxlevel)

canrecur(ctx::DepthLimitContext, f, args...) = ctx.level < ctx.maxlevel

function trackednested(ctx::DepthLimitContext, f_repr::TapeExpr,
                       args_repr::ArgumentTuple{TapeValue}, info::NodeInfo)
    new_ctx = increase_level(ctx)
    return recordnestedcall(new_ctx, f_repr, args_repr, info)
end



"""Composes behaviour of a series of other contexts (right to left, as with functions)."""
struct ComposedContext{T<:Tuple{Vararg{AbstractTrackingContext}}} <: AbstractTrackingContext
    contexts::T
    ComposedContext(contexts::T) where {T<:Tuple{Vararg{AbstractTrackingContext}}} =
        new{T}(contexts)
end

ComposedContext(ctx::AbstractTrackingContext, contexts::AbstractTrackingContext...) =
    ComposedContext((ctx, contexts...))


function foldcontexts(composed::ComposedContext, track, args...)
    contexts = composed.contexts
    C = length(contexts)
    node = track(contexts[end], args...)
    
    for c = C:-1:2
        node = track(composed.context[c], args...)
    end

    return node
end


trackedreturn(composed::ComposedContext, arg_repr::TapeExpr, info::NodeInfo) =
    foldcontexts(composed, arg_repr, info)

trackedjump(composed::ComposedContext, target::Int, args_repr::ArgumentTuple{TapeValue},
            cond_repr::TapeExpr, info::NodeInfo) =
                foldcontexts(composed, target, args_repr, cond_repr, info)

trackedspecial(composed::ComposedContext, form_repr::TapeExpr, info::NodeInfo) =
    foldcontexts(composed, form_repr, info)

trackedconstant(composed::ComposedContext, const_repr::TapeExpr, info::NodeInfo) =
    foldcontexts(composed, const_repr, info)

trackedargument(composed::ComposedContext, arg_repr::TapeExpr, number::Int, info::NodeInfo) =
    foldcontexts(composed, arg_repr, number, info)

trackedprimitive(trackedprimitive(composed::AbstractTrackingContext, f_repr::TapeExpr,
                                  args_repr::ArgumentTuple{TapeExpr}, info::NodeInfo)) =
                                      foldcontexts(composed, f_repr, args_repr, info)

trackednested(trackedprimitive(composed::AbstractTrackingContext, f_repr::TapeExpr,
                               args_repr::ArgumentTuple{TapeExpr}, info::NodeInfo)) =
                                   foldcontexts(composed, f_repr, args_repr, info)

canrecur(composed::ComposedContext, f, args...) =
    any(canrecur(ctx, f, args...) for ctx in composed.contexts)
