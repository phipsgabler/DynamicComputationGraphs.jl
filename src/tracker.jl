using IRTools


record!(tape::GraphTape, node::Node) = (push!(tape, node); value(node))

@generated function record!(tape::GraphTape, index::VarIndex, expr, f::F, args...) where F
    # TODO: check this out:
    # @nospecialize args
    
    # from Cassette.canrecurse
    # (https://github.com/jrevels/Cassette.jl/blob/79eabe829a16b6612e0eba491d9f43dc9c11ff02/src/context.jl#L457-L473)
    mod = Base.typename(F).module
    is_builtin = ((F <: Core.Builtin) && !(mod === Core.Compiler)) || F <: Core.IntrinsicFunction
    
    if is_builtin 
        quote
            result = f(args...)
            call = PrimitiveCall(expr, result, index)
            push!(tape, call)
            return result
        end
    else
        quote
            result, graph = track(f, args...)
            call = NestedCall(expr, result, index, graph)
            push!(tape, call)
            return result
        end
    end
end


function track_branches!(block::IRTools.Block, vm::VariableMap, return_block, tape, branches)
    pseudo_return!(block, args...) = IRTools.branch!(block, return_block, args...)
    
    # called only from within a non-primitive call
    for (position, branch) in enumerate(branches)
        index = DCGCall.BranchIndex(block.id, position)
        args = map(substitute(vm), branch.args)
        reified_args = map(reify_quote, branch.args)
        
        if IRTools.isreturn(branch)
            @assert length(branch.args) == 1
            
            # record return statement
            return_record = push!(block, DCGCall.Return(reified_args[1], args[1], index))
            pseudo_return!(block, args[1], return_record)
        else
            condition = substitute(vm, branch.condition)
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


function track_statement!(block::IRTools.Block, vm::VariableMap, tape, variable, statement)
    index = DCGCall.VarIndex(block.id, variable.id)
    expr = statement.expr
    reified_expr = reify_quote(statement.expr)
    
    if Meta.isexpr(expr, :call)
        args = map(substitute(vm), expr.args)
        stmt_record = IRTools.stmt(DCGCall.record!(tape, index, reified_expr, args...),
                                   line = statement.line)
        r = push!(block, stmt_record)
        record_substitution!(vm, variable, r)
    elseif expr isa Expr
        # other special things, like `:new`, `:boundscheck`, or `:foreigncall`
        args = map(substitute(vm), expr.args)
        special_evaluation = Expr(expr.head, args...)
        special_value = push!(block, special_evaluation)
        special_expr = DCGCall.SpecialStatement(reified_expr, special_value, index)
        special_record = IRTools.stmt(DCGCall.record!(tape, special_expr),
                                      line = statement.line)
        r = push!(block, special_record)
        record_substitution!(vm, variable, r)
    elseif expr isa QuoteNode || expr isa GlobalRef
        # for statements that are just constants (like type literals), or global values
        constant_expr = DCGCall.Constant(expr, index)
        # TODO: make constant_expr itself a constant :)
        constant_record = IRTools.stmt(DCGCall.record!(tape, constant_expr),
                                       line = statement.line)
        r = push!(block, constant_record)
        record_substitution!(vm, variable, r)
    else
        # currently unhandled
        error("Found statement of unknown type: ", statement)
    end
    
    return nothing
end


function copy_argument!(block::IRTools.Block, vm::VariableMap, argument)
    # without `insert = false`, `nothing` gets added to branches pointing here
    new_argument = IRTools.argument!(block, insert = false)
    record_substitution!(vm, argument, new_argument)
end


function track_argument!(block::IRTools.Block, vm::VariableMap, tape, argument)
    index = DCGCall.VarIndex(block.id, argument.id)
    new_argument = substitute(vm, argument)
    argument_record = DCGCall.record!(tape, DCGCall.Argument(new_argument, index))
    push!(block, argument_record)
end


function track_jump!(new_block::IRTools.Block, tape, branch_argument)
    jump_record = DCGCall.record!(tape, branch_argument)
    push!(new_block, jump_record)
end


function track_block!(new_block::IRTools.Block, vm::VariableMap, jt::JumpTargets, return_block,
                      tape, old_block; first = false)
    @assert first || !isnothing(tape)

    # copy over arguments from old block
    for argument in IRTools.arguments(old_block)
        copy_argument!(new_block, vm, argument)
    end

    # if this is the first block, set up the tape
    if first
        original_ir = old_block.ir
        tape = push!(new_block, DCGCall.GraphTape(copy(original_ir)))
    end

    # record branches to here, if there are any, by adding a new argument
    if haskey(jt, old_block.id)
        branch_argument = IRTools.argument!(new_block, insert = false)
        track_jump!(new_block, tape, branch_argument)
    end

    # record rest of the arguments from the old block
    for argument in IRTools.arguments(old_block)
        track_argument!(new_block, vm, tape, argument)
    end

    # handle statement recording (nested vs. primitive is handled in `record!`)
    for (v, stmt) in old_block
        track_statement!(new_block, vm, tape, v, stmt)
    end

    # set up branch tracking and returning the tape
    track_branches!(new_block, vm, return_block, tape, IRTools.branches(old_block))

    return tape
end


# tracking the first block is special, because only there the tape is set up
track_first_block!(new_block::IRTools.Block, vm::VariableMap, jt::JumpTargets, return_block, old_block) =
    track_block!(new_block, vm, jt, return_block, nothing, old_block, first = true)


function setup_return_block!(new_ir::IRTools.IR, tape)
    return_block = IRTools.block!(new_ir)
    return_value = IRTools.argument!(return_block, insert = false)
    push!(return_block, DCGCall.record!(tape, IRTools.argument!(return_block, insert = false)))
    IRTools.return!(return_block, IRTools.xcall(:tuple, return_value, tape))
    return return_block
end


function track_ir(old_ir::IRTools.IR)
    IRTools.explicitbranch!(old_ir) # make implicit jumps explicit
    new_ir = IRTools.empty(old_ir)
    vm = VariableMap()
    jt = jumptargets(old_ir)

    # in new_ir, the first block is already set up automatically, 
    # so we just use it and set up the tape there
    old_first_block = IRTools.block(old_ir, 1)
    new_first_block = IRTools.block(new_ir, 1)
    return_block = length(old_ir.blocks) + 1

    tape = track_first_block!(new_first_block, vm, jt, return_block, old_first_block)

    # the rest of the blocks needs to be created newly, and can use `tape`.
    for (i, old_block) in enumerate(IRTools.blocks(old_ir))
        i == 1 && continue
        
        new_block = IRTools.block!(new_ir, i)
        track_block!(new_block, vm, jt, return_block, tape, old_block)
    end
    
    # now we set up a block at the last position, to which all return statements redirect.
    @assert setup_return_block!(new_ir, tape).id == return_block
    
    return new_ir
end


function error_ir(F, args...)
    # create empty IR which matches the (non-existing) signature given by f(args)
    dummy(args...) = nothing
    ir = IRTools.empty(IRTools.IR(IRTools.meta(Tuple{Core.Typeof(dummy), Core.Typeof.(args)...})))
    
    self = IRTools.argument!(ir)
    arg_values = ntuple(_ -> IRTools.argument!(ir), length(args))

    if F <: Core.IntrinsicFunction
        error_result = push!(ir, DCGCall.print_intrinsic_error(self, arg_values...))
        IRTools.return!(ir, error_result)
        return ir
    else
        error_result = push!(ir, IRTools.xcall(:error, "Can't track ", F,
                                               " with args ", join(args, ", ")))
        IRTools.return!(ir, error_result)
        return ir
    end
end



export track

IRTools.@dynamo function track(F, args...)
    # println("handling $F with args $args")
    ir = IRTools.IR(F, args...)

    if isnothing(ir)
        return error_ir(F, args...)
    else
        new_ir = track_ir(ir)
        # @show ir
        # @show new_ir
        return new_ir
    end
    
end



