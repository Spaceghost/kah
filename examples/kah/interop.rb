# Lua's module system and globals are available from compiled Ruby.
math = Lua.require("math")
puts math.sqrt(81).to_i
puts Lua.global("type").call("kah")
