using IRTools: Block, IR, Variable

mutable struct TrackBuilder
    original_ir::IR
    new_ir::IR
    variable_map::Dict{Any, Any}
    jump_targets::Dict{Int, Vector{Int}}
    return_block::Int
    tape::Union{IRTools.Variable, Nothing}

    TrackBuilder(o, n, v, j, r) = new(o, n, v, j, r)
end

function TrackBuilder(ir)
    new_ir = empty(ir)
    variable_map = Dict{Any, Any}()
    jump_targets = jumptargets(ir)
    return_block = length(ir.blocks) + 1

    TrackBuilder(ir, new_ir, variable_map, jump_targets, return_block)
end


substitute_variable(builder::TrackBuilder, x) = get(builder.variable_map, x, x)
substitute_variable(builder::TrackBuilder) = x -> substitute_variable(builder, x)

record_new_variable!(builder::TrackBuilder, x, y) = (push!(builder.variable_map, x => y); builder)

function jumptargets(ir::IR)
    targets = Dict{Int, Vector{Int}}()
    pushtarget!(from, to) = push!(get!(targets, to, Int[]), from)
    
    for block in IRTools.blocks(ir)
        branches = IRTools.branches(block)
        
        for branch in branches
            if !IRTools.isreturn(branch)
                pushtarget!(block.id, branch.block)

                if IRTools.isconditional(branch) && branch == branches[end]
                    # conditional branch with fallthrough (last of all)
                    pushtarget!(block.id, block.id + 1)
                end
            end
        end
    end

    return targets
end

hasjumpto(builder, block) = haskey(builder.jump_targets, block.id)

function pushrecord!(builder::TrackBuilder, block::Block, args...;
                     substituting = nothing, line = 0)
    record = IRTools.stmt(DCGCall.record!(builder.tape, args...), line = line)
    r = push!(block, record)
    !isnothing(substituting) && record_new_variable!(builder, substituting, r)
    return r
end



function track_branches!(builder::TrackBuilder, block::Block, branches)
    pseudo_return!(block, args...) = IRTools.branch!(block, builder.return_block, args...)
    
    # called only from within a non-primitive call
    for (position, branch) in enumerate(branches)
        index = DCGCall.BranchIndex(block.id, position)
        args = map(substitute_variable(builder), branch.args)
        reified_args = map(reify_quote, branch.args)
        
        if IRTools.isreturn(branch)
            @assert length(branch.args) == 1
            
            # record return statement
            return_record = push!(block, DCGCall.Return(reified_args[1], args[1], index))
            pseudo_return!(block, args[1], return_record)
        else
            condition = substitute_variable(builder, branch.condition)
            reified_condition = reify_quote(branch.condition)
            
            # remember from where and why we branched in target_info
            arg_exprs = IRTools.xcall(:vect, reified_args...)
            arg_values = IRTools.xcall(:vect, args...)
            jump_record = DCGCall.Branch(branch.block, arg_exprs, arg_values,
                                         reified_condition, index)
            target_info = push!(block, jump_record)

            # extend branch args by target_info
            IRTools.branch!(block, branch.block, args..., target_info; unless = condition)
        end
    end

    return block
end


function track_statement!(builder::TrackBuilder, block::Block, variable, statement)
    index = DCGCall.VarIndex(block.id, variable.id)
    expr = statement.expr
    reified_expr = reify_quote(statement.expr)
    
    if Meta.isexpr(expr, :call)
        args = map(substitute_variable(builder), expr.args)
        pushrecord!(builder, block, index, reified_expr, args...,
                    line = statement.line, substituting = variable)
    elseif expr isa Expr
        # other special things, like `:new`, `:boundscheck`, or `:foreigncall`
        args = map(substitute_variable(builder), expr.args)
        special_evaluation = Expr(expr.head, args...)
        special_value = push!(block, special_evaluation)
        special_expr = DCGCall.SpecialStatement(reified_expr, special_value, index)
        pushrecord!(builder, block, special_expr, line = statement.line, substituting = variable)
    elseif expr isa QuoteNode || expr isa GlobalRef
        # for statements that are just constants (like type literals), or global values
        constant_expr = DCGCall.Constant(expr, index)
        # TODO: make constant_expr itself a constant :)
        pushrecord!(builder, block, constant_expr, line = statement.line, substituting = variable)
    else
        # currently unhandled
        error("Found statement of unknown type: ", statement)
    end
    
    return nothing
end


function copy_argument!(builder::TrackBuilder, block::Block, argument)
    # without `insert = false`, `nothing` gets added to branches pointing here
    new_argument = IRTools.argument!(block, insert = false)
    record_new_variable!(builder, argument, new_argument)
end


function track_argument!(builder::TrackBuilder, block::Block, argument)
    index = DCGCall.VarIndex(block.id, argument.id)
    new_argument = substitute_variable(builder, argument)
    pushrecord!(builder, block, DCGCall.Argument(new_argument, index))
end


function track_jump!(builder::TrackBuilder, new_block::IRTools.Block, branch_argument)
    pushrecord!(builder, new_block, branch_argument)
end


function setup_tape!(builder::TrackBuilder)
    first_block = IRTools.block(builder.new_ir, 1)
    return builder.tape = push!(first_block, DCGCall.GraphTape(copy(builder.original_ir)))
end


function track_block!(builder::TrackBuilder, new_block::Block, old_block; first = false)
    @assert first || !isnothing(builder.tape)

    # copy over arguments from old block
    for argument in IRTools.arguments(old_block)
        copy_argument!(builder, new_block, argument)
    end

    # if this is the first block, set up the tape
    first && setup_tape!(builder)

    # record branches to here, if there are any, by adding a new argument
    if hasjumpto(builder, old_block)
        branch_argument = IRTools.argument!(new_block, insert = false)
        track_jump!(builder, new_block, branch_argument)
    end

    # track rest of the arguments from the old block
    for argument in IRTools.arguments(old_block)
        track_argument!(builder, new_block, argument)
    end

    # handle statement recording (nested vs. primitive is handled in `record!`)
    for (v, stmt) in old_block
        track_statement!(builder, new_block, v, stmt)
    end

    # set up branch tracking
    track_branches!(builder, new_block, IRTools.branches(old_block))

    return new_block
end


# tracking the first block is special, because only there the tape is set up
track_first_block!(builder::TrackBuilder, new_block::Block, old_block) =
    track_block!(builder, new_block, old_block, first = true)


function setup_return_block!(builder::TrackBuilder)
    return_block = IRTools.block!(builder.new_ir)
    @assert return_block.id == builder.return_block
    
    return_value = IRTools.argument!(return_block, insert = false)
    pushrecord!(builder, return_block, IRTools.argument!(return_block, insert = false))
    IRTools.return!(return_block, IRTools.xcall(:tuple, return_value, builder.tape))
    return return_block
end



function build_tracks!(builder::TrackBuilder)
    # in new_ir, the first block is already set up automatically, 
    # so we just use it and set up the tape there
    old_first_block = IRTools.block(builder.original_ir, 1)
    new_first_block = IRTools.block(builder.new_ir, 1)
    return_block = length(builder.original_ir.blocks) + 1

    track_first_block!(builder, new_first_block, old_first_block)

    # the rest of the blocks needs to be created newly, and can use `tape`.
    for (i, old_block) in enumerate(IRTools.blocks(builder.original_ir))
        i == 1 && continue
        
        new_block = IRTools.block!(builder.new_ir, i)
        track_block!(builder, new_block, old_block)
    end
    
    # now we set up a block at the last position, to which all return statements redirect.
    setup_return_block!(builder)

    return builder.new_ir
end