require_relative "../native"
KahNative.kah_native_init
ast = KahAST.new('puts "a\\0b"', "native-bridge.rb")
raise "wrong root kind" unless ast.kind(ast.root) == "ProgramNode"
raise "invalid node kind" unless ast.kind(-1) == ""
raise "invalid node reference" unless ast.ref(-1, "statements") == -1
body = ast.ref(ast.root, "statements")
call = ast.list(body, "body")[0]
raise "wrong call name" unless ast.text(call, "name") == "puts"
arg = ast.list(ast.ref(call, "arguments"), "arguments")[0]
copy = ast.text(arg, "content")
raise "binary string corrupted" unless copy.bytes == [97, 0, 98]
ast.text(call, "name")
raise "text return was borrowed" unless copy.bytes == [97, 0, 98]
raise "unexpected parser error" unless ast.error_count == 0
other = KahAST.new("puts 1\nif\n", "invalid.rb")
raise "parser errors missing" unless other.error_count > 0
raise "source line missing" unless other.error_line(0) > 0
raise "error text missing" unless other.error_message(0).length > 0
other.close
raise "second context corrupted first" unless ast.kind(ast.root) == "ProgramNode"
ast.close
puts "PASS native bridge: typed AST, binary strings, owned results, independent contexts, diagnostics"
