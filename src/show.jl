import Base: show


printlevels(io::IO, value, levels::Integer) = print(IOContext(io, :maxlevel => levels), value)
printlevels(value, levels::Integer) = printlevels(stdout::IO, value, levels)

showvalue(io::IO, value) = show(IOContext(io, :limit => true), value)
showvalue(io::IO, value::Nothing) = show(io, repr(value))
# showvalue(io::IO, value) = repr(value, context = IOContext(io, :limit => true, :compact => true))


function joinlimited(io::IO, values, delim)
    L = length(values)
    if L > 0
        for (i, value) in enumerate(values)
            showvalue(io, value)
            i != L && print(io, delim)
        end
    end
end

maybespace(str) = isempty(str) ? "" : " "
printlocation(io::IO, ix::IRIndex, postfixes...) = printlocation(io, "", ix, postfixes...)
printlocation(io::IO, prefix, ix::IRIndex, postfixes...) =
    print(io, "[", prefix, maybespace(prefix), ix, "]", maybespace(postfixes), postfixes...)
printlocation(io::IO, prefix, ::NoIndex, postfixes...) = 
    print(io, postfixes...)


function show(io::IO, node::ConstantNode, level = 1)
    printlocation(io, "Constant", location(node), " = ")
    showvalue(io, value(node))
end

function show(io::IO, node::PrimitiveCallNode, level = 1)
    printlocation(io, location(node), node.call, " = ")
    showvalue(io, value(node))
end

function show(io::IO, node::NestedCallNode, level = 1)
    maxlevel = get(io, :maxlevel, typemax(level))
    printlocation(io, location(node), node.call, " = ")
    showvalue(io, value(node))

    if level < maxlevel
        print(io, "\n") # prevent double newlines
        for (i, child) in enumerate(node)
            print(io, "  " ^ level, "@", i, ": ")
            show(io, child, level + 1)
            i < length(node) && print(io, "\n")
        end
    end
end

function show(io::IO, node::SpecialCallNode, level = 1)
    printlocation(io, location(node), node.form, " = ")
    showvalue(io, value(node))
end

function show(io::IO, node::ArgumentNode, level = 1)
    printlocation(io, "Argument", location(node), "= ")
    showvalue(io, value(node))
end

function show(io::IO, node::ReturnNode, level = 1)
    printlocation(io, location(node), "return ", node.argument, " = ")
    showvalue(io, value(node.argument))
end

function show(io::IO, node::JumpNode, level = 1)
    printlocation(io, location(node), "goto §", node.target)
    L = length(node.arguments)

    if L > 0
        print(io, " (")
        for (i, argument) in enumerate(node.arguments)
            (argument isa TapeReference) && print(io, argument, "= ")
            showvalue(io, value(argument))
            i != L && print(io, ", ")
        end
        print(io, ")")
    end

    reason = value(node.condition)
    if !isnothing(reason)
        print(io, " since ", reason)
    end
end

show(io::IO, index::VarIndex) = print(io, "§", index.block, ":%", index.line, "")
show(io::IO, index::BranchIndex) = print(io, "§", index.block, ":", index.line)

show(io::IO, expr::TapeReference) = print(io, "@", expr.index)
show(io::IO, expr::TapeConstant) = showvalue(io, expr.value)

function show(io::IO, expr::TapeCall)
    print(io, expr.f, "(")
    joinlimited(io, expr.arguments, ", ")
    print(io, ")")
end

function show(io::IO, expr::TapeSpecialForm)
    print(io, expr.head, "(")
    joinlimited(io, expr.arguments, ", ")
    print(io, ")")
end

# show(io::IO, info::StatementInfo)= 
    # print(io, "StatementInfo(", something(info.metadata, ""), ")")
