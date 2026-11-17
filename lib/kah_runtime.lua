-- Kah's shared runtime. Syntax deliberately stays within Lua 5.1.
local _R = (function()
  local R = {}
  local unpack_values = table.unpack or unpack
  local MAX_INT = 9007199254740991
  local NIL = {}
  local symbols = {}
  local function decode(value) if value == NIL then return nil end; return value end
  local function tag(x) return type(x) == "table" and x.__kah or type(x) end
  local function fail(kind, message) error(kind .. ": " .. message, 0) end
  R.fail = fail
  function R.pack(...) return {n = select("#", ...), ...} end
  function R.truth(x) return x ~= nil and x ~= false end
  function R.int(x)
    if x ~= x or math.abs(x) > MAX_INT or x ~= math.floor(x) then
      fail("RangeError", "integer exceeds Kah's exact portable range (+/- 9007199254740991)")
    end
    return x
  end
  local float_values = setmetatable({}, {__mode = "v"})
  function R.float(x)
    x = x * 1.0
    if x ~= x then return {__kah = "float", value = x} end
    local key = x
    if x == 0 and 1 / x == -math.huge then key = "-0" end
    local value = float_values[key]
    if not value then value = {__kah = "float", value = x}; float_values[key] = value end
    return value
  end
  local function hash_key(key)
    if tag(key) == "float" and key.value == 0 then return R.float(0.0) end
    return key
  end
  local function number(x)
    if type(x) == "number" then return x * 1.0 end
    if tag(x) == "float" then return x.value * 1.0 end
    fail("TypeError", "expected a number")
  end
  function R.symbol(name)
    if not symbols[name] then symbols[name] = {__kah = "symbol", value = name} end
    return symbols[name]
  end
  function R.array(values) return {__kah = "array", data = values, n = values.n} end
  function R.hash(pairs)
    local h = {__kah = "hash", data = {}, keys = {}, n = 0}
    for i = 1, pairs.n, 2 do R.hash_set(h, pairs[i], pairs[i + 1]) end
    return h
  end
  function R.hash_set(h, key, value)
    if key == nil then key = NIL end
    local lookup_key = hash_key(key)
    if h.data[lookup_key] == nil then h.n = h.n + 1; h.keys[h.n] = key end
    h.data[lookup_key] = value == nil and NIL or value
    return value
  end
  function R.range(first, last, exclusive)
    R.int(first); R.int(last)
    return {__kah = "range", first = first, last = last, exclusive = exclusive}
  end
  function R.env(parent) return {parent = parent, values = {}} end
  local function scope(env, depth)
    for _ = 1, depth do env = env.parent end
    return env.values
  end
  function R.local_get(env, depth, name) return scope(env, depth)[name] end
  function R.local_set(env, depth, name, value) scope(env, depth)[name] = value; return value end
  function R.control(target, value) error({__kah_control = target, value = value}, 0) end
  function R.run(target, fn)
    local ok, result = pcall(fn)
    if ok then return result end
    if type(result) == "table" and result.__kah_control == target then return result.value end
    error(result, 0)
  end
  function R.block(fn) return {__kah = "block", fn = fn, token = {}} end
  function R.invoke(block, args)
    if not block then fail("LocalJumpError", "no block given") end
    return block.fn(args, block.token)
  end
  function R.block_args(args, count)
    if count > 1 and args.n == 1 and tag(args[1]) == "array" then
      local a = args[1]; local r = {n = a.n}
      for i = 1, a.n do r[i] = a.data[i] end
      return r
    end
    return args
  end
  function R.rest(args, start)
    local values = {n = math.max(0, args.n - start + 1)}
    for i = start, args.n do values[i - start + 1] = args[i] end
    return R.array(values)
  end
  function R.arity(args, min, max)
    if args.n < min or (max >= 0 and args.n > max) then
      fail("ArgumentError", "wrong number of arguments (given " .. args.n .. ", expected " .. min .. (max ~= min and (max < 0 and "+" or ".." .. max) or "") .. ")")
    end
  end
  local function klass(name, super, parent, module)
    return {__kah = "class", name = name, super = super, parent = parent,
      methods = {}, singleton = {}, constants = {}, mixins = {}, module = module}
  end
  R.Object = klass("Object")
  local Object = R.Object
  for _, name in ipairs({"Array", "Hash", "String", "Integer", "Float", "Symbol", "NilClass", "TrueClass", "FalseClass", "Range", "Proc", "Class", "Module"}) do
    Object.constants[name] = klass(name, Object, Object)
  end
  Object.constants.Object = Object
  Object.constants.RUBY_ENGINE = "kah"
  Object.constants.RUBY_VERSION = "3.4.0"
  Object.constants.KAH_VERSION = "0.1.0"
  function R.object(class) return {__kah = "object", class = class, ivars = {}, singleton = {}} end
  function R.constget(owner, name)
    local current = owner
    while current do
      if current.constants[name] ~= nil then return current.constants[name] end
      current = current.parent
    end
    if Object.constants[name] ~= nil then return Object.constants[name] end
    fail("NameError", "uninitialized constant " .. name)
  end
  function R.constset(owner, name, value) owner.constants[name] = value; return value end
  function R.define_class(owner, name, super, module)
    local old = owner.constants[name]
    if old then
      if tag(old) ~= "class" or old.module ~= module or (super and old.super ~= super) then
        fail("TypeError", "incompatible reopening of " .. name)
      end
      return old
    end
    if super and (tag(super) ~= "class" or super.module) then fail("TypeError", "superclass must be a Class") end
    local class = klass(owner == Object and name or owner.name .. "::" .. name, super or Object, owner, module)
    owner.constants[name] = class
    return class
  end
  function R.define(owner, receiver, name, fn)
    if receiver == nil then owner.methods[name] = fn
    elseif type(receiver) == "table" and receiver.singleton then receiver.singleton[name] = fn
    else fail("TypeError", "cannot define a singleton method on this value") end
    return R.symbol(name)
  end
  local function classof(x)
    local k = tag(x)
    if k == "object" then return x.class end
    local names = {array = "Array", hash = "Hash", string = "String", number = "Integer", float = "Float",
      symbol = "Symbol", ["nil"] = "NilClass", boolean = x and "TrueClass" or "FalseClass", range = "Range", block = "Proc", class = "Class"}
    return Object.constants[names[k]] or Object
  end
  local function lookup(class, name)
    if not class then return nil end
    if class.methods[name] then return class.methods[name] end
    for i = 1, #class.mixins do
      local fn = lookup(class.mixins[i], name)
      if fn then return fn end
    end
    return lookup(class.super, name)
  end
  local function singleton_lookup(class, name)
    if class.singleton[name] then return class.singleton[name] end
    if class.super then return singleton_lookup(class.super, name) end
  end
  function R.ivar_get(self, name) return self.ivars[name] end
  function R.ivar_set(self, name, value) self.ivars[name] = value; return value end
  function R.equal(a, b, seen)
    if a == b then return true end
    local ak, bk = tag(a), tag(b)
    if (ak == "number" or ak == "float") and (bk == "number" or bk == "float") then return number(a) == number(b) end
    if ak == "array" and bk == "array" and a.n == b.n then
      seen = seen or {}; if seen[a] == b then return true end; seen[a] = b
      for i = 1, a.n do if not R.equal(a.data[i], b.data[i], seen) then return false end end
      return true
    end
    return false
  end
  local function float_string(value)
    if value ~= value then return "NaN" end
    if value == math.huge then return "Infinity" end
    if value == -math.huge then return "-Infinity" end
    local s, digits
    for precision = 1, 17 do
      s = string.format("%." .. precision .. "g", value)
      digits = precision
      if tonumber(s) == value then break end
    end
    local mantissa, exponent = s:match("^(.-)[eE]([+-]?%d+)$")
    if exponent then
      local power = tonumber(exponent)
      if power >= -4 and power < 15 then
        s = string.format("%." .. math.max(0, digits - 1 - power) .. "f", value)
      else
        if not mantissa:find("%.") then mantissa = mantissa .. ".0" end
        return mantissa .. "e" .. exponent
      end
    end
    if not s:find("%.") then s = s .. ".0" end
    return s
  end
  function R.inspect(x, seen)
    local k = tag(x)
    if x == nil then return "nil" end
    if k == "string" then
      return '"' .. x:gsub('[%z\1-\31\\"]', function(c)
        return ({['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t', ['\\'] = '\\\\', ['"'] = '\\"'})[c] or string.format("\\u%04X", string.byte(c))
      end) .. '"'
    end
    if k == "symbol" then
      if x.value:match("^[_%a][_%w]*[?!]?$") then return ":" .. x.value end
      return ":" .. R.inspect(x.value)
    end
    if k == "float" then return float_string(x.value) end
    if k == "number" then return string.format("%.0f", x) end
    if k == "boolean" then return tostring(x) end
    if k == "class" then return x.name end
    seen = seen or {}
    if seen[x] then return k == "array" and "[...]" or "{...}" end
    seen[x] = true
    local out = {}
    if k == "array" then
      for i = 1, x.n do out[i] = R.inspect(x.data[i], seen) end
      seen[x] = nil; return "[" .. table.concat(out, ", ") .. "]"
    end
    if k == "hash" then
      for i = 1, x.n do
        local key = x.keys[i]; local val = x.data[hash_key(key)]
        local prefix
        if tag(key) == "symbol" then
          prefix = (key.value:match("^[_%a][_%w]*[?!]?$") and key.value or R.inspect(key.value)) .. ": "
        else prefix = R.inspect(decode(key), seen) .. " => " end
        out[i] = prefix .. R.inspect(decode(val), seen)
      end
      seen[x] = nil; return "{" .. table.concat(out, ", ") .. "}"
    end
    if k == "range" then return R.inspect(x.first) .. (x.exclusive and "..." or "..") .. R.inspect(x.last) end
    return "#<" .. classof(x).name .. ">"
  end
  function R.to_s(x)
    if x == nil then return "" end
    if type(x) == "string" then return x end
    if tag(x) == "symbol" then return x.value end
    local method = lookup(classof(x), "to_s")
    if method then return method(x, {n = 0}, nil) end
    return R.inspect(x)
  end
  local function puts(x, seen)
    if tag(x) == "array" then
      seen = seen or {}; if seen[x] then io.write("[...]\n"); return end
      seen[x] = true
      for i = 1, x.n do puts(x.data[i], seen) end
      seen[x] = nil
    else
      local s = R.to_s(x); io.write(s)
      if s:sub(-1) ~= "\n" then io.write("\n") end
    end
  end
  local function index(i, n)
    if type(i) ~= "number" then fail("TypeError", "index must be an Integer") end
    if i < 0 then i = n + i end
    return i + 1
  end
  local function each_value(receiver, callback)
    local k = tag(receiver)
    if k == "array" then
      local i = 1
      while i <= receiver.n do callback(R.pack(receiver.data[i])); i = i + 1 end
    elseif k == "hash" then
      for i = 1, receiver.n do
        local key = receiver.keys[i]; local val = receiver.data[hash_key(key)]
        callback(R.pack(R.array(R.pack(decode(key), decode(val)))))
      end
    elseif k == "range" then
      local stop = receiver.last - (receiver.exclusive and 1 or 0)
      for i = receiver.first, stop do callback(R.pack(i)) end
    else fail("NoMethodError", "undefined method 'each'") end
  end
  local function native(value) return {__kah = "lua", value = value} end
  function R.unwrap(value)
    local k = tag(value)
    if k == "lua" or k == "float" or k == "symbol" then return value.value end
    if k == "array" then
      local out = {}; for i = 1, value.n do out[i] = R.unwrap(value.data[i]) end; return out
    end
    if k == "hash" then
      local out = {}
      for i = 1, value.n do
        local key = value.keys[i]; local v = value.data[hash_key(key)]
        if key == NIL then fail("TypeError", "Lua tables cannot have nil keys") end
        out[R.unwrap(key)] = R.unwrap(decode(v))
      end
      return out
    end
    if k == "block" then
      return function(...) return R.unwrap(R.invoke(value, R.pack(...))) end
    end
    return value
  end
  function R.wrap(value)
    if type(value) == "number" then return R.float(value) end
    if type(value) == "table" or type(value) == "function" or type(value) == "userdata" then return native(value) end
    return value
  end
  local function native_call(fn, args)
    local out = {}
    for i = 1, args.n do out[i] = R.unwrap(args[i]) end
    return R.wrap(fn(unpack_values(out, 1, args.n)))
  end
  Object.constants.Lua = {__kah = "lua_root"}
  function R.send(receiver, name, args, block)
    local k = tag(receiver)
    local fn
    if type(receiver) == "table" and receiver.singleton then fn = receiver.singleton[name] end
    if not fn and k == "class" then fn = singleton_lookup(receiver, name) end
    fn = fn or lookup(classof(receiver), name)
    if fn then return fn(receiver, args, block) end
    if name == "nil?" then return receiver == nil end
    if name == "!" then return not R.truth(receiver) end
    if name == "==" then return R.equal(receiver, args[1]) end
    if name == "!=" then return not R.truth(R.send(receiver, "==", args, nil)) end
    if name == "equal?" then return receiver == args[1] end
    if name == "to_s" then return R.to_s(receiver) end
    if name == "inspect" then return R.inspect(receiver) end
    if name == "class" then return classof(receiver) end
    if name == "itself" then return receiver end
    if name == "puts" then
      if args.n == 0 then io.write("\n") end
      for i = 1, args.n do puts(args[i]) end; return nil
    end
    if name == "print" then for i = 1, args.n do io.write(R.to_s(args[i])) end; return nil end
    if name == "p" then
      for i = 1, args.n do io.write(R.inspect(args[i]), "\n") end
      if args.n == 0 then return nil end
      if args.n == 1 then return args[1] end; return R.array(args)
    end
    if name == "raise" or name == "fail" then fail("RuntimeError", args[1] and R.to_s(args[1]) or "") end
    if name == "block_given?" then return block ~= nil end
    if k == "lua_root" then
      if name == "require" then return R.wrap(require(args[1])) end
      if name == "global" then return R.wrap(_G[args[1]]) end
    elseif k == "lua" then
      if name == "call" and type(receiver.value) == "function" then return native_call(receiver.value, args) end
      local key = name
      if name == "[]" then key = R.unwrap(args[1]) end
      local value = receiver.value[key]
      if type(value) == "function" then return native_call(value, args) end
      if args.n == 0 or name == "[]" then return R.wrap(value) end
    elseif k == "class" then
      if name == "new" then
        if receiver == Object.constants.Array then
          local n = args[1] or 0; R.int(n)
          if n < 0 then fail("ArgumentError", "negative array size") end
          local data = {n = n}
          for i = 1, n do
            if block then data[i] = R.invoke(block, R.pack(i - 1)) else data[i] = args[2] end
          end
          return R.array(data)
        end
        if receiver == Object.constants.Hash then
          if args.n > 0 or block then fail("NotImplementedError", "Hash defaults are not supported") end
          return R.hash({n = 0})
        end
        local obj = R.object(receiver)
        local init = lookup(receiver, "initialize")
        if init then init(obj, args, block) else R.arity(args, 0, 0) end
        return obj
      end
      if name == "attr_reader" or name == "attr_writer" or name == "attr_accessor" then
        for i = 1, args.n do
          local field = R.to_s(args[i]); local ivar = "@" .. field
          if name ~= "attr_writer" then receiver.methods[field] = function(self) return R.ivar_get(self, ivar) end end
          if name ~= "attr_reader" then receiver.methods[field .. "="] = function(self, a) return R.ivar_set(self, ivar, a[1]) end end
        end
        return R.array(args)
      end
      if name == "include" then
        for i = 1, args.n do
          local mixin = args[i]
          if tag(mixin) ~= "class" or not mixin.module then fail("TypeError", "include expects a module") end
          table.insert(receiver.mixins, 1, mixin)
        end
        return receiver
      end
    elseif k == "number" or k == "float" then
      local a = number(receiver)
      if name == "to_i" then return R.int(a < 0 and math.ceil(a) or math.floor(a)) end
      if name == "to_f" then return R.float(a) end
      if name == "zero?" then return a == 0 end
      if name == "even?" then return a % 2 == 0 end
      if name == "odd?" then return a % 2 ~= 0 end
      if name == "abs" then return k == "float" and R.float(math.abs(a)) or R.int(math.abs(a)) end
      if name == "-@" then return k == "float" and R.float(-a) or R.int(-a) end
      if name == "+@" then return receiver end
      if name == "times" or name == "upto" or name == "downto" then
        if k ~= "number" then fail("NoMethodError", "integer iterator on Float") end
        local first, last, step = 0, a - 1, 1
        if name == "upto" then first, last = a, number(args[1]) end
        if name == "downto" then first, last, step = a, number(args[1]), -1 end
        for i = first, last, step do R.invoke(block, R.pack(i)) end
        return receiver
      end
      local b = number(args[1]); local result
      local floating = k == "float" or tag(args[1]) == "float"
      if name == "+" then result = a + b
      elseif name == "-" then result = a - b
      elseif name == "*" then result = a * b
      elseif name == "/" then
        if not floating and b == 0 then fail("ZeroDivisionError", "divided by 0") end
        result = floating and a / b or math.floor(a / b)
      elseif name == "%" then
        if b == 0 then fail("ZeroDivisionError", "divided by 0") end
        result = a % b
      elseif name == "**" then
        if not floating and b < 0 then fail("NotImplementedError", "negative integer powers require Rational") end
        result = a ^ b
      elseif name == "<" then return a < b
      elseif name == "<=" then return a <= b
      elseif name == ">" then return a > b
      elseif name == ">=" then return a >= b
      elseif name == "<=>" then return a < b and -1 or (a > b and 1 or 0)
      else fail("NoMethodError", "undefined numeric method '" .. name .. "'") end
      return floating and R.float(result) or R.int(result)
    elseif k == "array" then
      if name == "[]" then local i = index(args[1], receiver.n); return receiver.data[i] end
      if name == "[]=" then
        local i = index(args[1], receiver.n)
        if i < 1 then fail("IndexError", "index too small") end
        receiver.data[i] = args[2]; receiver.n = math.max(receiver.n, i); return args[2]
      end
      if name == "length" or name == "size" then return receiver.n end
      if name == "empty?" then return receiver.n == 0 end
      if name == "first" then return receiver.data[1] end
      if name == "last" then return receiver.data[receiver.n] end
      if name == "push" or name == "<<" then
        for i = 1, args.n do receiver.n = receiver.n + 1; receiver.data[receiver.n] = args[i] end; return receiver
      end
      if name == "pop" then
        local value = receiver.data[receiver.n]
        if receiver.n > 0 then receiver.data[receiver.n] = nil; receiver.n = receiver.n - 1 end
        return value
      end
      if name == "join" then
        local out = {}; for i = 1, receiver.n do out[i] = R.to_s(receiver.data[i]) end
        return table.concat(out, args[1] or "")
      end
      if name == "to_a" then return receiver end
    elseif k == "hash" then
      if name == "[]" then local v = receiver.data[hash_key(args[1] == nil and NIL or args[1])]; if v ~= NIL then return v end; return nil end
      if name == "[]=" then return R.hash_set(receiver, args[1], args[2]) end
      if name == "size" or name == "length" then return receiver.n end
      if name == "empty?" then return receiver.n == 0 end
      if name == "key?" or name == "has_key?" then return receiver.data[hash_key(args[1] == nil and NIL or args[1])] ~= nil end
      if name == "keys" or name == "values" then
        local out = {n = receiver.n}
        for i = 1, receiver.n do
          local v
          if name == "keys" then v = receiver.keys[i] else v = receiver.data[hash_key(receiver.keys[i])] end
          if v ~= NIL then out[i] = v end
        end
        return R.array(out)
      end
    elseif k == "string" then
      if name == "+" then if type(args[1]) ~= "string" then fail("TypeError", "expected a String") end; return receiver .. args[1] end
      if name == "*" then return string.rep(receiver, args[1]) end
      if name == "length" or name == "size" or name == "bytesize" then return #receiver end
      if name == "empty?" then return #receiver == 0 end
      if name == "upcase" then return string.upper(receiver) end
      if name == "downcase" then return string.lower(receiver) end
      if name == "to_sym" then return R.symbol(receiver) end
      if name == "to_i" then return R.int(tonumber(receiver:match("^%s*([+-]?%d+)")) or 0) end
      if name == "[]" then
        local i = index(args[1], #receiver)
        if i < 1 or i > #receiver then return nil end
        return receiver:sub(i, args.n > 1 and i + args[2] - 1 or i)
      end
    elseif k == "symbol" then
      if name == "to_sym" then return receiver end
    elseif k == "block" and name == "call" then
      return R.invoke(receiver, args)
    end
    if k == "array" or k == "hash" or k == "range" then
      if name == "each" or name == "map" or name == "collect" or name == "select" or name == "each_with_index" or name == "to_a" then
        local result = {n = 0}; local i = 0
        each_value(receiver, function(values)
          local value = values[1]
          if name == "to_a" then result.n = result.n + 1; result[result.n] = value
          elseif name == "each_with_index" then R.invoke(block, R.pack(value, i))
          else
            local mapped = R.invoke(block, values)
            if name == "map" or name == "collect" or (name == "select" and R.truth(mapped)) then
              result.n = result.n + 1
              if name == "select" then result[result.n] = value else result[result.n] = mapped end
            end
          end
          i = i + 1
        end)
        if name == "each" or name == "each_with_index" then return receiver end
        return R.array(result)
      end
    end
    fail("NoMethodError", "undefined method '" .. name .. "' for " .. classof(receiver).name)
  end
  function R.call(receiver, name, args, block)
    if block then return R.run(block.token, function() return R.send(receiver, name, args, block) end) end
    return R.send(receiver, name, args, nil)
  end
  function R.exports(self)
    return {call = function(name, ...) return R.unwrap(R.send(self, name, R.pack(...), nil)) end,
      version = "0.1.0", engine = "kah"}
  end
  return R
end)()
