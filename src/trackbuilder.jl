using IRTools: Block, IR, Statement, Variable
using IRTools: argument!, block, blocks, branches, branch!, return!
import IRTools: block!


"""
    TrackBuilder(ir)

Context type used to build up new IR with tracking functionality from the original `ir`.  Keeps
track of necessary intermediate information.
"""
mutable struct TrackBuilder
    original_ir::IR
    new_ir::IR
    
    """Map from SSA variable in the original IR to the respective variables in the new IR."""
    variable_map::Dict{Any, Any}
    """of Labels the blocks from which there are jumps to every block (mapping target -> sources)."""
    jump_targets::Dict{Int, Vector{Int}}
    """Number (label) of the unified return block to be added at the end."""
    return_block::Int
    
    """SSA variable for the `GraphRecorder` used at runtime."""
    recorder::Union{Variable, Nothing}
    """SSA variable for the tracking context."""
    context::Union{Variable, Nothing}
end

function TrackBuilder(ir::IR)
    new_ir = empty(ir)
    variable_map = Dict{Any, Any}()
    jump_targets = jumptargets(ir)
    return_block = length(ir.blocks) + 1

    TrackBuilder(ir, new_ir, variable_map, jump_targets, return_block, nothing, nothing)
end


"""
    block(builder[, i]) -> Block

Create a new block in the IR constructed by `builder`.  If `i == 0`, then return the default 
first block in empty IR.
"""
block!(builder::TrackBuilder) = block!(builder.new_ir)
block!(builder::TrackBuilder, i) =
    (i == 1) ? block(builder.new_ir, 1) : block!(builder.new_ir)

"""Substitute the variable `x` in original IR with its replacement in the newly built IR."""
substitute_variable(builder::TrackBuilder, x) = get(builder.variable_map, x, x)
substitute_variable(builder::TrackBuilder) = x -> substitute_variable(builder, x)

"""Record variable `x` in original IR to be substituted by `y` in the new IR."""
record_new_variable!(builder::TrackBuilder, x, y) = (push!(builder.variable_map, x => y); builder)

"""Check whether there exists a jump to block `block`"""
hasjumpto(builder::TrackBuilder, block) = haskey(builder.jump_targets, block.id)


"""Extract a dictionary mapping each block to the blocks to which you can jump from there."""
function jumptargets(ir::IR)
    targets = Dict{Int, Vector{Int}}()
    pushtarget!(from, to) = push!(get!(targets, to, Int[]), from)
    
    for block in blocks(ir), branch in branches(block)
        if !IRTools.isreturn(branch)
            pushtarget!(block.id, branch.block)

            if IRTools.isconditional(branch) && branch == branches(block)[end]
                # conditional branch with fallthrough (last of all)
                pushtarget!(block.id, block.id + 1)
            end
        end
    end

    return targets
end


inlined(value) = QuoteNode(value)


"""
    tapevalue(builder, value)

Transform a value (i.e., a SSA variable or a constant) occuring in an `Expr` or other part of a 
SSA statement into a `TapeValue` call, or an inlined `TapeValue`, if possible.
"""

function tapevalue(builder::TrackBuilder, value::IRTools.Variable)
    original = substitute_variable(builder, value)
    return IRTCall.trackedvariable(builder.recorder, inlined(value), original)
end

function tapevalue(builder::TrackBuilder, value::Any)
    return inlined(TapeConstant(value))
end

function tapevalue(builder::TrackBuilder, value::GlobalRef)
    # GlobalRefs can be resolved only at runtime, so we leave then in a non-inlined expression
    return IRTCall.TapeConstant(value)
end

function tapevalue(builder::TrackBuilder, value::QuoteNode)
    # some (many?) constants are already wrapped in a QuoteNode -- we simply re-wrap
    return inlined(TapeConstant(value.value))
end


"""
    tapevalues(builder, values)

Construct an expression returning a tuple of `TapeValues`, given by transforming `values` using
`tapevalue`.
"""
function tapevalues(builder::TrackBuilder, values)
    return BaseCall.tuple(tapevalue.(Ref(builder), values)...)
end


# The XYZrecord functions all record a complex `Expr` creating a node for tracking (at runtime)
# the respective kind of SSA statement.  This `Expr` can then be pushed to the IR, followed by an
# `Expr` calling `pushrecord!` on it, to actually track it on the `GraphRecorder`.

function returnrecord(builder::TrackBuilder, location, branch)
    argument_repr = tapevalue(builder, branch.args[1])
    return IRTCall.trackedreturn(builder.recorder, argument_repr, location)
end

function jumprecord(builder::TrackBuilder, location, branch)
    condition_repr = tapevalue(builder, branch.condition)
    arguments_repr = tapevalues(builder, branch.args)
    return IRTCall.trackedjump(builder.recorder, branch.block, arguments_repr,
                               condition_repr, location)
end

function callrecord(builder::TrackBuilder, location, call_expr)
    f_expr, arguments_expr = call_expr.args[1], call_expr.args[2:end]
    f_repr = tapevalue(builder, f_expr)
    arguments_repr = tapevalues(builder, arguments_expr)
    return IRTCall.trackedcall(builder.recorder, f_repr, arguments_repr, location)
end

function specialrecord(builder::TrackBuilder, location, special_expr)
    head = special_expr.head
    args = map(substitute_variable(builder), special_expr.args)
    form = Expr(head, args...)
    args_repr = tapevalues(builder, special_expr.args)
    form_repr = IRTCall.TapeSpecialForm(form, QuoteNode(head), args_repr)
    return IRTCall.trackedspecial(builder.recorder, form_repr, location)
end

function constantrecord(builder::TrackBuilder, location, constant_expr)
    constant_repr = tapevalue(builder, constant_expr)
    return IRTCall.trackedconstant(builder.recorder, constant_repr, location)
end

function argumentrecord(builder::TrackBuilder, location, argument_expr, parent_branch, number)
    argument_repr = IRTCall.TapeConstant(substitute_variable(builder, argument_expr))
    return IRTCall.trackedargument(builder.recorder, argument_repr, parent_branch, number, location)
end


"""
    pushrecord!(builder, block, record; substituting = var)

Add to `block`` the IR necessary to record `record`, which should be an expression returning a
`Node`.  If `substituting` is given, it is recorded as being substituted by this new SSA variable in
the transformed IR.
"""
function pushrecord!(builder::TrackBuilder, block::Block, record;
                     substituting = nothing, line = 0)
    r = push!(block, IRTools.stmt(IRTCall.record!(builder.recorder, record), line = line))
    isnothing(substituting) || record_new_variable!(builder, substituting, r)
    return r
end


function trackbranches!(builder::TrackBuilder, new_block::Block, branches)
    # called only from within a non-primitive call
    for (i, branch) in enumerate(branches)
        location = inlined(BranchIndex(new_block.id, i))
        substituted_args = map(substitute_variable(builder), branch.args)
        
        if IRTools.isreturn(branch)
            # the return is converted to a branch, redirecting to a new last block,
            # where it gets recorded
            return_record = push!(new_block, returnrecord(builder, location, branch))
            branch!(new_block, builder.return_block, substituted_args..., return_record)
        else
            # remember from where and why we branched, and extend branch arguments
            branch_record = push!(new_block, jumprecord(builder, location, branch))
            branch!(new_block, branch.block, substituted_args..., branch_record;
                    unless = substitute_variable(builder, branch.condition))
        end
    end

    return new_block
end


function iscglobal(expr)
    if Meta.isexpr(expr, :call, 3)
        f = expr.args[1]
        if f isa GlobalRef
            return f.name == :cglobal
        else
            return f == :cglobal
        end
    end

    return false
end

function trackstatement!(builder::TrackBuilder, new_block::Block,
                          variable::Variable, statement::Statement)
    location = inlined(VarIndex(new_block.id, variable.id))
    expr = statement.expr
    
    if Meta.isexpr(expr, :call) && !iscglobal(expr)
        # normal call expression; nested vs. primitive is handled in `record!`
        # except `cglobal`, which has to be treated like a `ccall` `:foreigncall`, but
        # isn't lowered like a `ccall`.
        record = callrecord(builder, location, expr)
    elseif expr isa Expr
        # other special things, like `:new`, `:boundscheck`, or `:foreigncall`
        record = specialrecord(builder, location, expr)
    else
        # everything else is a constant evaluating to itself
        # many constants are wrapped in `QuoteNode`s, but some aren't...
        record = constantrecord(builder, location, expr)
    end

    pushrecord!(builder, new_block, record, line = statement.line, substituting = variable)
    return new_block
end


function trackarguments!(builder::TrackBuilder, new_block::Block, old_block::Block; isfirst = false)
    # copy over arguments from old block
    for argument in IRTools.arguments(old_block)
        # without `insert = false`, `nothing` gets added to branches pointing here
        new_argument = argument!(new_block, insert = false)
        record_new_variable!(builder, argument, new_argument)
    end

    # this is the first block, here we set up the recorder argument
    if isfirst
        _self = argument!(new_block, at = 1, insert = false)
        builder.recorder = argument!(new_block, at = 2, insert = false)
        push!(new_block, IRTCall.saveir!(builder.recorder, inlined(copy(builder.original_ir))))
    end
    
    # record jumps to here, if there are any, by adding a new argument and recording it
    parent_branch = inlined(nothing)
    if hasjumpto(builder, old_block)
        branch_argument = argument!(new_block, insert = false)
        pushrecord!(builder, new_block, branch_argument)
        
        # this is stored in argument nodes to point back to the variables they come from
        if !isfirst && length(IRTools.arguments(old_block)) > 0
            parent_branch = branch_argument
        end
    end

    # track rest of the arguments from the old block
    for (i, argument) in enumerate(IRTools.arguments(old_block))
        location = inlined(VarIndex(new_block.id, argument.id))
        number = inlined(i)
        record = argumentrecord(builder, location, argument, parent_branch, number)
        pushrecord!(builder, new_block, record)
    end

    return new_block
end


function trackblock!(builder::TrackBuilder, new_block::Block, old_block::Block; isfirst = false)
    @assert isfirst || isdefined(builder, :recorder)

    trackarguments!(builder, new_block, old_block, isfirst = isfirst)

    for (v, stmt) in old_block
        trackstatement!(builder, new_block, v, stmt)
    end

    # set up branch tracking
    trackbranches!(builder, new_block, branches(old_block))

    return new_block
end


"""
    insert_return_block!(builder)

Set up the common return block in tracking IR.  All returns in the original IR are replaced by 
explicit jumps to the common `builder.return_block`, to be able to record return statements.

This needs to be done _after_ all blocks of the new IR have been created from the old blocks!
"""
function insert_return_block!(builder::TrackBuilder)
    return_block = block!(builder)
    @assert return_block.id == builder.return_block
    
    return_value = argument!(return_block, insert = false)
    branch_node = argument!(return_block, insert = false)
    pushrecord!(builder, return_block, branch_node)
    return!(return_block, return_value)
    return return_block
end


"""
    buildtracks!(builder)

Create new IR with tracking code from original IR in the `builder`, and return it.
"""
function buildtracks!(builder::TrackBuilder)
    for (i, old_block) in enumerate(blocks(builder.original_ir))
        new_block = block!(builder, i)
        trackblock!(builder, new_block, old_block, isfirst = i == 1)
    end
    
    # now we set up a block at the last position, to which all return statements redirect.
    insert_return_block!(builder)

    return builder.new_ir
end
