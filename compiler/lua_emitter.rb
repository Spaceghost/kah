# Portable compiler logic. Spinel compiles this Ruby into the Kah executable.
# Native ownership, Prism access, and OS calls live behind KahNative in Nelua.
class KahLuaEmitter
  attr_reader :failed
  def initialize(ast, runtime, load_paths)
    @ast = ast
    @runtime = runtime
    @lines = []
    @next = 0
    @indent = 0
    @nesting = 0
    @loop = 0
    @block = false
    @failed = false
    @load_paths = load_paths
    @known_files = []
    @loader_lines = []
  end
  def fresh
    @next += 1
    @next
  end
  def value(id)
    "_v[#{id}]"
  end
  def line(text)
    @lines << "#{'  ' * @indent}#{text}\n"
  end
  def quote(text)
    result = '"'
    i = 0
    while i < text.bytesize
      byte = text.getbyte(i)
      if byte == 34 || byte == 92
        result = result + "\\" + byte.chr
      elsif byte < 32 || byte >= 127
        digits = byte.to_s
        result = result + "\\" + "0" * (3 - digits.length) + digits
      else
        result = result + byte.chr
      end
      i += 1
    end
    result + '"'
  end
  def qfield(node, name)
    quote(@ast.text(node, name))
  end
  def refuse(node, reason)
    STDERR.puts "kah: #{@ast.path}:#{@ast.int(node, 'node_line')}: Lua backend does not support #{reason} (#{@ast.kind(node)})"
    @failed = true
  end
  def nil_value
    id = fresh
    line "#{value(id)} = nil"
    id
  end
  def values(node, name)
    nodes = @ast.list(node, name)
    ids = []
    nodes.each { |child| ids << expr(child) }
    result = fresh
    line "#{value(result)} = {n = #{ids.length}}"
    i = 0
    while i < ids.length
      line "#{value(result)}[#{i + 1}] = #{value(ids[i])}"
      i += 1
    end
    result
  end
  def arguments(node)
    values(@ast.ref(node, 'arguments'), 'arguments')
  end
  def bind(param, index)
    line "_R.local_set(_e, 0, #{qfield(param, 'name')}, _args[#{index}])"
  end
  def parameters(node, block)
    node = @ast.ref(node, 'parameters') if @ast.kind(node) == 'BlockParametersNode'
    if @ast.kind(node) == 'NumberedParametersNode'
      count = @ast.int(node, 'maximum')
      line "_args = _R.block_args(_args, #{count})"
      i = 1
      while i <= count
        line "_R.local_set(_e, 0, #{quote('_' + i.to_s)}, _args[#{i}])"
        i += 1
      end
      return
    end
    if node < 0
      line '_R.arity(_args, 0, 0)' unless block
      return
    end
    if @ast.kind(node) != 'ParametersNode'
      refuse(node, 'this parameter form')
      return
    end
    required = @ast.list(node, 'requireds')
    optional = @ast.list(node, 'optionals')
    keywords = @ast.list(node, 'keywords')
    posts = @ast.list(node, 'posts')
    rest = @ast.ref(node, 'rest')
    block_param = @ast.ref(node, 'block')
    if keywords.length > 0 || posts.length > 0 || @ast.ref(node, 'keyword_rest') >= 0
      refuse(node, 'keyword or post-rest parameters')
      return
    end
    if block
      line "_args = _R.block_args(_args, #{required.length + optional.length})"
    else
      maximum = rest < 0 ? required.length + optional.length : -1
      line "_R.arity(_args, #{required.length}, #{maximum})"
    end
    i = 0
    while i < required.length
      refuse(required[i], 'destructured parameters') if @ast.kind(required[i]) != 'RequiredParameterNode'
      bind(required[i], i + 1)
      i += 1
    end
    i = 0
    while i < optional.length
      at = required.length + i + 1
      line "if _args.n < #{at} then"
      @indent += 1
      default = expr(@ast.ref(optional[i], 'value'))
      line "_args[#{at}] = #{value(default)}"
      @indent -= 1
      line 'end'
      bind(optional[i], at)
      i += 1
    end
    if rest >= 0
      refuse(rest, 'argument forwarding') if @ast.kind(rest) != 'RestParameterNode'
      line "_R.local_set(_e, 0, #{qfield(rest, 'name')}, _R.rest(_args, #{required.length + optional.length + 1}))"
    end
    if block_param >= 0
      line "_R.local_set(_e, 0, #{qfield(block_param, 'name')}, _block)"
    end
  end
  def block_expr(node)
    kind = @ast.kind(node)
    return expr(@ast.ref(node, 'expression')) if kind == 'BlockArgumentNode'
    if kind != 'BlockNode'
      refuse(node, 'this block form')
      return nil_value
    end
    result = fresh
    saved_loop = @loop
    saved_block = @block
    line "#{value(result)} = _R.block(function(_args, _brk)"
    @indent += 1
    line 'local _e = _R.env(_e)'
    line 'local _v = {}'
    @loop = 0
    @block = true
    parameters(@ast.ref(node, 'parameters'), true)
    body = expr(@ast.ref(node, 'body'))
    line "return #{value(body)}"
    @indent -= 1
    line 'end)'
    @loop = saved_loop
    @block = saved_block
    result
  end
  def constant_owner(path)
    result = fresh
    parent = @ast.ref(path, 'parent')
    if @ast.kind(path) == 'ConstantPathNode'
      if parent >= 0
        owner = expr(parent)
        line "#{value(result)} = #{value(owner)}"
      else
        line "#{value(result)} = _R.Object"
      end
    else
      line "#{value(result)} = _owner"
    end
    result
  end
  def assignment(node, rhs)
    kind = @ast.kind(node)
    name = qfield(node, 'name')
    result = fresh
    if kind == 'InstanceVariableWriteNode' || kind == 'InstanceVariableOperatorWriteNode' || kind == 'InstanceVariableOrWriteNode' || kind == 'InstanceVariableAndWriteNode'
      line "#{value(result)} = _R.ivar_set(_self, #{name}, #{value(rhs)})"
    elsif kind == 'ConstantWriteNode'
      line "#{value(result)} = _R.constset(_owner, #{name}, #{value(rhs)})"
    elsif kind == 'GlobalVariableWriteNode' || kind == 'GlobalVariableOperatorWriteNode' || kind == 'GlobalVariableOrWriteNode' || kind == 'GlobalVariableAndWriteNode'
      line "#{value(result)} = #{value(rhs)}; _globals[#{name}] = #{value(rhs)}"
    else
      line "#{value(result)} = _R.local_set(_e, #{@ast.int(node, 'depth')}, #{name}, #{value(rhs)})"
    end
    result
  end
  def load_file(node, method)
    arguments = @ast.list(@ast.ref(node, 'arguments'), 'arguments')
    if arguments.length != 1 || @ast.kind(arguments[0]) != 'StringNode'
      refuse(node, 'computed Ruby requires')
      return nil_value
    end
    name = @ast.text(arguments[0], 'content')
    name = name + '.rb' unless name.end_with?('.rb')
    path = ''
    if method == 'require_relative'
      path = File.expand_path(name, File.dirname(@ast.path))
    elsif name.start_with?('/') || name.start_with?('./') || name.start_with?('../')
      path = File.expand_path(name)
    else
      @load_paths.each do |root|
        candidate = File.expand_path(name, root)
        path = candidate if path.empty? && File.exist?(candidate)
      end
      path = File.expand_path(name) if path.empty?
    end
    unless File.exist?(path)
      refuse(node, "unresolved local Ruby require #{name}")
      return nil_value
    end
    unless @known_files.include?(path)
      @known_files << path
      imported = KahAST.new(File.read(path), path)
      saved_ast = @ast
      saved_lines = @lines
      saved_indent = @indent
      saved_loop = @loop
      saved_block = @block
      begin
        @ast = imported
        if imported.error_count > 0
          i = 0
          while i < imported.error_count
            STDERR.puts "kah: #{path}:#{imported.error_line(i)}: #{imported.error_message(i)}"
            i += 1
          end
          @failed = true
        else
          @lines = []
          @indent = 0
          @loop = 0
          @block = false
          line "_kah_loaders[#{quote(path)}] = function()"
          @indent += 1
          line 'local _owner = _R.Object'
          line 'local _self = _kah_main'
          line 'local _e = _R.env(nil)'
          line 'local _v = {}'
          line 'local _block = nil'
          line 'local _ret = {}'
          line 'return _R.run(_ret, function()'
          @indent += 1
          expr(imported.root)
          @indent -= 1
          line 'end)'
          @indent -= 1
          line 'end'
          @loader_lines << @lines.join
        end
      ensure
        @ast = saved_ast
        @lines = saved_lines
        @indent = saved_indent
        @loop = saved_loop
        @block = saved_block
        imported.close
      end
    end
    result = fresh
    key = quote(path)
    line "if _kah_loaded[#{key}] then"
    @indent += 1
    line "#{value(result)} = false"
    @indent -= 1
    line 'else'
    @indent += 1
    line "_kah_loaded[#{key}] = true"
    line "_kah_loaders[#{key}]()"
    line "#{value(result)} = true"
    @indent -= 1
    line 'end'
    result
  end
  def expr(node)
    @nesting += 1
    if @nesting > 512
      refuse(node, 'nesting deeper than 512 nodes')
      @nesting -= 1
      return nil_value
    end
    result = expression(node)
    @nesting -= 1
    result
  end
  def expression(node)
    return nil_value if node < 0
    kind = @ast.kind(node)
    result = fresh
    if kind == 'ProgramNode'
      return expr(@ast.ref(node, 'statements'))
    elsif kind == 'StatementsNode'
      body = @ast.list(node, 'body')
      return nil_value if body.empty?
      body.each { |child| result = expr(child) }
      return result
    elsif kind == 'ParenthesesNode'
      return expr(@ast.ref(node, 'body'))
    elsif kind == 'BeginNode'
      if @ast.ref(node, 'rescue_clause') >= 0 || @ast.ref(node, 'ensure_clause') >= 0 || @ast.ref(node, 'else_clause') >= 0
        refuse(node, 'rescue/ensure')
        return nil_value
      end
      return expr(@ast.ref(node, 'statements'))
    elsif kind == 'ElseNode' || kind == 'EmbeddedStatementsNode'
      return expr(@ast.ref(node, 'statements'))
    elsif kind == 'IntegerNode'
      integer = @ast.int(node, 'value')
      refuse(node, 'integer literals outside the exact portable range (+/- 9007199254740991)') unless @ast.text(node, 'bigval').empty?
      line "#{value(result)} = #{integer}"
    elsif kind == 'FloatNode'
      line "#{value(result)} = _R.float(#{@ast.text(node, 'value_text')})"
    elsif kind == 'StringNode'
      line "#{value(result)} = #{qfield(node, 'content')}"
    elsif kind == 'SymbolNode'
      line "#{value(result)} = _R.symbol(#{qfield(node, 'value')})"
    elsif kind == 'InterpolatedStringNode'
      line "#{value(result)} = \"\""
      @ast.list(node, 'parts').each do |part|
        v = expr(part)
        line "#{value(result)} = #{value(result)} .. _R.to_s(#{value(v)})"
      end
    elsif kind == 'NilNode'
      line "#{value(result)} = nil"
    elsif kind == 'TrueNode' || kind == 'FalseNode'
      text = kind == 'TrueNode' ? 'true' : 'false'
      line "#{value(result)} = #{text}"
    elsif kind == 'SelfNode'
      line "#{value(result)} = _self"
    elsif kind == 'LocalVariableReadNode'
      line "#{value(result)} = _R.local_get(_e, #{@ast.int(node, 'depth')}, #{qfield(node, 'name')})"
    elsif kind == 'InstanceVariableReadNode'
      line "#{value(result)} = _R.ivar_get(_self, #{qfield(node, 'name')})"
    elsif kind == 'GlobalVariableReadNode'
      line "#{value(result)} = _globals[#{qfield(node, 'name')}]"
    elsif kind == 'ConstantReadNode'
      line "#{value(result)} = _R.constget(_owner, #{qfield(node, 'name')})"
    elsif kind == 'ConstantPathNode'
      owner = constant_owner(node)
      line "#{value(result)} = _R.constget(#{value(owner)}, #{qfield(node, 'name')})"
    elsif kind == 'LocalVariableWriteNode' || kind == 'InstanceVariableWriteNode' || kind == 'ConstantWriteNode' || kind == 'GlobalVariableWriteNode'
      return assignment(node, expr(@ast.ref(node, 'value')))
    elsif kind == 'LocalVariableOperatorWriteNode' || kind == 'InstanceVariableOperatorWriteNode' || kind == 'GlobalVariableOperatorWriteNode'
      current = fresh
      if kind == 'LocalVariableOperatorWriteNode'
        line "#{value(current)} = _R.local_get(_e, #{@ast.int(node, 'depth')}, #{qfield(node, 'name')})"
      elsif kind == 'GlobalVariableOperatorWriteNode'
        line "#{value(current)} = _globals[#{qfield(node, 'name')}]"
      else
        line "#{value(current)} = _R.ivar_get(_self, #{qfield(node, 'name')})"
      end
      rhs = expr(@ast.ref(node, 'value'))
      line "#{value(result)} = _R.call(#{value(current)}, #{qfield(node, 'binary_operator')}, {n = 1, [1] = #{value(rhs)}}, nil)"
      return assignment(node, result)
    elsif kind == 'LocalVariableOrWriteNode' || kind == 'LocalVariableAndWriteNode' || kind == 'InstanceVariableOrWriteNode' || kind == 'InstanceVariableAndWriteNode' || kind == 'GlobalVariableOrWriteNode' || kind == 'GlobalVariableAndWriteNode'
      if kind == 'LocalVariableOrWriteNode' || kind == 'LocalVariableAndWriteNode'
        line "#{value(result)} = _R.local_get(_e, #{@ast.int(node, 'depth')}, #{qfield(node, 'name')})"
      elsif kind == 'GlobalVariableOrWriteNode' || kind == 'GlobalVariableAndWriteNode'
        line "#{value(result)} = _globals[#{qfield(node, 'name')}]"
      else
        line "#{value(result)} = _R.ivar_get(_self, #{qfield(node, 'name')})"
      end
      is_or = kind == 'LocalVariableOrWriteNode' || kind == 'InstanceVariableOrWriteNode' || kind == 'GlobalVariableOrWriteNode'
      negation = is_or ? 'not ' : ''
      line "if #{negation}_R.truth(#{value(result)}) then"
      @indent += 1
      rhs = assignment(node, expr(@ast.ref(node, 'value')))
      line "#{value(result)} = #{value(rhs)}"
      @indent -= 1
      line 'end'
    elsif kind == 'ArrayNode'
      elements = values(node, 'elements')
      line "#{value(result)} = _R.array(#{value(elements)})"
    elsif kind == 'HashNode' || kind == 'KeywordHashNode'
      elements = @ast.list(node, 'elements')
      pairs = fresh
      line "#{value(pairs)} = {n = #{elements.length * 2}}"
      i = 0
      while i < elements.length
        assoc = elements[i]
        if @ast.kind(assoc) != 'AssocNode'
          refuse(assoc, 'hash splats')
        else
          key = expr(@ast.ref(assoc, 'key'))
          v = expr(@ast.ref(assoc, 'value'))
          line "#{value(pairs)}[#{i * 2 + 1}] = #{value(key)}; #{value(pairs)}[#{i * 2 + 2}] = #{value(v)}"
        end
        i += 1
      end
      line "#{value(result)} = _R.hash(#{value(pairs)})"
    elsif kind == 'RangeNode'
      left = expr(@ast.ref(node, 'left'))
      right = expr(@ast.ref(node, 'right'))
      excluded = @ast.flag(node, 'exclude_end') ? 'true' : 'false'
      line "#{value(result)} = _R.range(#{value(left)}, #{value(right)}, #{excluded})"
    elsif kind == 'AndNode' || kind == 'OrNode'
      left = expr(@ast.ref(node, 'left'))
      line "#{value(result)} = #{value(left)}"
      negation = kind == 'OrNode' ? 'not ' : ''
      line "if #{negation}_R.truth(#{value(result)}) then"
      @indent += 1
      right = expr(@ast.ref(node, 'right'))
      line "#{value(result)} = #{value(right)}"
      @indent -= 1
      line 'end'
    elsif kind == 'IfNode' || kind == 'UnlessNode'
      predicate = expr(@ast.ref(node, 'predicate'))
      negation = kind == 'UnlessNode' ? 'not ' : ''
      line "if #{negation}_R.truth(#{value(predicate)}) then"
      @indent += 1
      yes = expr(@ast.ref(node, 'statements'))
      line "#{value(result)} = #{value(yes)}"
      @indent -= 1
      line 'else'
      @indent += 1
      field = kind == 'UnlessNode' ? 'else_clause' : 'subsequent'
      no = expr(@ast.ref(node, field))
      line "#{value(result)} = #{value(no)}"
      @indent -= 1
      line 'end'
    elsif kind == 'WhileNode' || kind == 'UntilNode'
      saved_loop = @loop
      loop_id = fresh
      fresh
      @loop = loop_id
      line "#{value(result)} = nil"
      line "#{value(loop_id)} = false"
      line 'while true do'
      @indent += 1
      post = @ast.flag(node, 'post_test')
      unless post
        condition = expr(@ast.ref(node, 'predicate'))
        negation = kind == 'WhileNode' ? 'not ' : ''
        line "if #{negation}_R.truth(#{value(condition)}) then break end"
      end
      line 'repeat'
      @indent += 1
      expr(@ast.ref(node, 'statements'))
      @indent -= 1
      line 'until true'
      line "if #{value(loop_id)} then #{value(result)} = #{value(loop_id + 1)}; break end"
      if post
        condition = expr(@ast.ref(node, 'predicate'))
        negation = kind == 'WhileNode' ? 'not ' : ''
        line "if #{negation}_R.truth(#{value(condition)}) then break end"
      end
      @indent -= 1
      line 'end'
      @loop = saved_loop
    elsif kind == 'ReturnNode'
      args = arguments(node)
      line "_R.control(_ret, #{value(args)}.n > 1 and _R.array(#{value(args)}) or #{value(args)}[1])"
      return nil_value
    elsif kind == 'BreakNode' || kind == 'NextNode'
      args = arguments(node)
      v = fresh
      line "#{value(v)} = #{value(args)}.n > 1 and _R.array(#{value(args)}) or #{value(args)}[1]"
      if @loop != 0
        if kind == 'BreakNode'
          line "#{value(@loop)} = true; #{value(@loop + 1)} = #{value(v)}"
        end
        line 'do break end'
      elsif @block
        if kind == 'BreakNode'
          line "_R.control(_brk, #{value(v)})"
        else
          line "do return #{value(v)} end"
        end
      else
        refuse(node, 'break/next outside a loop or block')
      end
      return nil_value
    elsif kind == 'YieldNode'
      args = arguments(node)
      line "#{value(result)} = _R.invoke(_block, #{value(args)})"
    elsif kind == 'CallNode'
      receiver_node = @ast.ref(node, 'receiver')
      name = @ast.text(node, 'name')
      if receiver_node < 0 && (name == 'require_relative' || name == 'require')
        return load_file(node, name)
      end
      if receiver_node < 0 && name == 'block_given?'
        line "#{value(result)} = _block ~= nil"
        return result
      end
      if receiver_node < 0
        receiver = fresh
        line "#{value(receiver)} = _self"
      else
        receiver = expr(receiver_node)
      end
      safe = @ast.flag(node, 'safe_nav')
      if safe
        line "#{value(result)} = nil"
        line "if #{value(receiver)} ~= nil then"
        @indent += 1
      end
      args = arguments(node)
      block_node = @ast.ref(node, 'block')
      block = block_node < 0 ? nil_value : block_expr(block_node)
      line "#{value(result)} = _R.call(#{value(receiver)}, #{quote(name)}, #{value(args)}, #{value(block)})"
      line "#{value(result)} = #{value(args)}[#{value(args)}.n]" if @ast.flag(node, 'attr_write')
      if safe
        @indent -= 1
        line 'end'
      end
    elsif kind == 'DefNode'
      receiver_node = @ast.ref(node, 'receiver')
      receiver = receiver_node < 0 ? nil_value : expr(receiver_node)
      line "#{value(result)} = _R.define(_owner, #{value(receiver)}, #{qfield(node, 'name')}, function(_self, _args, _block)"
      @indent += 1
      line 'local _e = _R.env(nil)'
      line 'local _v = {}'
      line 'local _ret = {}'
      line 'return _R.run(_ret, function()'
      @indent += 1
      saved_loop = @loop
      saved_block = @block
      @loop = 0
      @block = false
      parameters(@ast.ref(node, 'parameters'), false)
      body = expr(@ast.ref(node, 'body'))
      line "return #{value(body)}"
      @loop = saved_loop
      @block = saved_block
      @indent -= 1
      line 'end)'
      @indent -= 1
      line 'end)'
    elsif kind == 'ClassNode' || kind == 'ModuleNode'
      path = @ast.ref(node, 'constant_path')
      owner = constant_owner(path)
      path_kind = @ast.kind(path)
      refuse(path, 'dynamic class names') if path_kind != 'ConstantReadNode' && path_kind != 'ConstantPathNode'
      parent = expr(@ast.ref(node, 'superclass'))
      line "#{value(result)} = (function(_owner)"
      @indent += 1
      line 'local _self = _owner'
      line 'local _e = _R.env(nil)'
      line 'local _v = {}'
      line 'local _block = nil'
      saved_loop = @loop
      saved_block = @block
      @loop = 0
      @block = false
      body = expr(@ast.ref(node, 'body'))
      line "return #{value(body)}"
      @loop = saved_loop
      @block = saved_block
      @indent -= 1
      is_module = kind == 'ModuleNode' ? 'true' : 'false'
      line "end)(_R.define_class(#{value(owner)}, #{qfield(path, 'name')}, #{value(parent)}, #{is_module}))"
    elsif kind == 'BlockNode' || kind == 'BlockArgumentNode'
      return block_expr(node)
    elsif kind == 'SourceFileNode'
      line "#{value(result)} = #{quote(@ast.path)}"
    elsif kind == 'SourceLineNode'
      line "#{value(result)} = #{@ast.int(node, 'node_line')}"
    else
      refuse(node, 'this syntax')
      line "#{value(result)} = nil"
    end
    result
  end
  def compile
    line '_R.run(_ret, function()'
    @indent += 1
    expr(@ast.root)
    @indent -= 1
    line 'end)'
    line 'return _R.exports(_self)'
    prefix = "-- Generated by Kah: Ruby -> Lua via Prism, Spinel, and Nelua.\n" + @runtime + "\n"
    prefix = prefix + 'local _globals = {}' + "\n"
    prefix = prefix + 'local _owner = _R.Object' + "\n"
    prefix = prefix + 'local _self = _R.object(_owner)' + "\n"
    prefix = prefix + 'local _kah_main = _self; local _kah_loaders = {}; local _kah_loaded = {}' + "\n"
    prefix = prefix + 'do local argv = {n = #(arg or {})}; for i = 1, argv.n do argv[i] = arg[i] end; _R.constset(_owner, "ARGV", _R.array(argv)) end' + "\n"
    prefix = prefix + 'local _e = _R.env(nil); local _v = {}; local _block = nil; local _ret = {}' + "\n"
    prefix + @loader_lines.join + @lines.join
  end
end
