#!/usr/bin/env python3
"""Differential Ruby semantics tests, using CRuby as the independent oracle."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
COMPILER = Path(os.environ.get('KAH_COMPILER', str(ROOT / 'bin' / 'kah')))
BOOTSTRAP = Path(os.environ.get('SPINEL_BOOTSTRAP', str(ROOT / 'bin' / 'spinel')))
CASES = {
    'literals': '''
p nil, true, false, 0, 42, 2.0
p :ruby == "ruby", :ruby == :ruby
p "a\\0b".bytesize, "a\\0b"
local = 12
p local
''',
    'arithmetic': '''
p 7 / 3, -7 / 3, 7 / -3, -7 % 3
p 7.0 / 2, 7 / 2.0, 1.5 + 2, 3 * 1.5, -2.5
p 2 ** 10, 3 <=> 8, 8 >= 3, 8.zero?, 0.zero?
p 1 == 1.0, 2 != 2.0, 2 == "2"
''',
    'float_formatting': '''
p 0.1, 1e15, 1e14, 1e-5, 1e-4, -0.0, 1.2345678901234567
p 1.0 / 0.0, -1.0 / 0.0, 0.0 / 0.0
h = {1 => \"integer\", 1.0 => \"float\"}
p h[1], h[1.0], h.size
''',
    'conditions': '''
p(if 0 then "zero is true" else "bad" end)
p(if "" then "empty is true" else "bad" end)
p(unless false then 12 else 14 end)
p(if false then 1 elsif nil then 2 else 3 end)
a = nil
false && (a = 12)
true || (a = 14)
p a, nil || false, false || 0, 0 && "yes", !0, !nil
''',
    'functions': '''
def fib(n)
  if n < 2
    n
  else
    fib(n - 1) + fib(n - 2)
  end
end
def defaults(a, b = 5, *rest)
  [a, b, rest]
end
p fib(15), defaults(1), defaults(1, nil), defaults(1, 2, 3, nil, false)
def early(x)
  return "negative" if x < 0
  x * 2
end
p early(-1), early(3)
''',
    'strings': '''
s = "kah"
p "#{s.upcase}: #{7 / 2} / #{nil} / #{false}"
p s + " lua", s * 2, s[0], s[-1], s[99], "-12x".to_i
p "9".to_sym == :"9"
''',
    'arrays': '''
a = [1, nil, false, 4, nil]
p a.size, a[-1], a[-2], a[99], a[-99]
p a.map { |x| x }, a.select { |x| true }
a[7] = false
p a, a.size, a.pop, a.size
p ["a", nil, "b"].join(":")
a.push(nil, 9)
p a.last, a.first, [].empty?
p [1, [nil, false]] == [1, [nil, false]]
''',
    'hashes': '''
h = {nil => false, false => nil, :name => "kah", "n" => 2}
p h, h[nil], h[false], h[:name], h["missing"]
p h.key?(false), h.key?(nil), h.key?(:missing), h.keys, h.values
h[false] = 12
p h[false], h.size
h.each { |key, value| p [key, value] }
''',
    'loops': '''
x = 0
value = while x < 8
  x += 1
  next if x == 2
  break [x, false] if x == 5
end
p x, value
n = 0
begin
  n += 1
end while false
p n
m = 0
until m == 3
  m += 1
end
p m
p(while true do break false end)
''',
    'nested_loops': '''
x = 0
a = while true
  inner = while true
    break 7
  end
  x += inner
  break x
end
p a
''',
    'closures': '''
total = 0
[1, 2, 3].each do |x|
  [4, 5].each { |y| total += x * y }
end
p total
p [[1, 2], [3, 4]].map { |a, b| a + b }
p [1, 2].map { _1 * 3 }
p [1, 2].map { it + 1 }
''',
    'blocks': '''
def with_value(x)
  p block_given?
  yield x
end
def forward(&callback)
  with_value(8, &callback)
end
p forward { |n| n * 2 }
def no_block
  block_given?
end
p no_block
p [1, 2, 3].map { |x| next nil if x == 2; x * 2 }
p [1, 2].each { |x| break false if x == 1 }
def from_block
  [1, 2].each { |x| return x + 40 }
  0
end
p from_block
''',
    'block_breaks': '''
p [1, 2, 3].map { |x| break [x, nil] if x == 2; x }
p 5.times { |n| break 77 if n == 3 }
def custom_yield
  yield 3
  100
end
p custom_yield { |x| break x * 4 }
''',
    'classes': '''
module Greeting
  def hello
    "hello #{@name}"
  end
end
class Person
  include Greeting
  attr_accessor :name
  def initialize(name)
    @name = name
  end
  def self.kind
    "person"
  end
end
class Writer < Person
  def label
    "writer: #{@name}"
  end
end
p Person.kind
writer = Writer.new("Kah")
p writer.name, writer.hello, writer.label
p(writer.name = "Lua")
p writer.name, writer.class
''',
    'constants': '''
module Moon
  NAME = "Lua"
  class Ruby
    def label
      NAME
    end
  end
end
p Moon::NAME, Moon::Ruby.new.label
ANSWER = false
p ANSWER
''',
    'ranges': '''
p (1..4).map { |n| n * 2 }, (1...4).to_a, (4..1).to_a
p 3.times { |n| print n }
print "\\n"
1.upto(3) { |n| print n }
print "\\n"
3.downto(1) { |n| print n }
print "\\n"
''',
    'safe_navigation': '''
$called = 0
def side_effect
  $called += 1
end
nothing = nil
p nothing&.missing(side_effect)
p $called
p false&.to_s
''',
    'assignment_values': '''
a = nil
a ||= false
p a
a ||= 3
p a
a &&= 4
p a
class Assignment
  def initialize
    @value = nil
  end
  def value
    @value ||= false
    @value ||= 8
    @value += 2
  end
  def odd=(v)
    "wrong writer result"
  end
end
obj = Assignment.new
p obj.value
p(obj.odd = 7)
''',
    'constructors': '''
p Array.new(4), Array.new(3, false)
p Array.new(4) { |i| next false if i == 0; next nil if i == 1; i }
p Hash.new
''',
    'arguments': '''
p ARGV, ARGV.size, ARGV[1]
''',
    'evaluation_order': '''
$log = []
def observe(n)
  $log << n
  n
end
def combine(a, b)
  a * 10 + b
end
p combine(observe(1), observe(2))
p [observe(3), observe(4)]
p $log
''',
}
REFUSALS = {
    'big_integer': 'p 9007199254740992',
    'wide_integer': 'p 9999999999999999999999999999999',
    'rescue': 'begin; raise "x"; rescue; puts "caught"; end',
    'keyword_parameters': 'def f(x: 1); x; end; p f',
    'unsupported_syntax': 'case 1; when 1; puts 2; end',
    'syntax_error': 'def missing(',
}


def run(command, **kwargs):
    return subprocess.run([str(x) for x in command], capture_output=True, timeout=30, **kwargs)


def assert_ok(result, context):
    if result.returncode:
        raise AssertionError(f'{context}: exit {result.returncode}\n{result.stderr.decode(errors="replace")}')


def main():
    ruby = shutil.which(os.environ.get('RUBY', 'ruby'))
    if not ruby:
        raise SystemExit('CRuby is required as the differential oracle')
    requested = shlex.split(os.environ.get('LUA_VMS', 'lua5.1 luajit lua5.4 lua5.5'))
    vms = [shutil.which(vm) for vm in requested]
    vms = [vm for vm in vms if vm]
    if not any('luajit' in vm for vm in vms) or not any('luajit' not in vm for vm in vms):
        raise SystemExit('Both LuaJIT and at least one standard Lua interpreter are required')
    executions = 0
    with tempfile.TemporaryDirectory(prefix='kah-tests-', dir=os.environ.get('TMPDIR')) as directory:
        work = Path(directory)
        for name, source in CASES.items():
            rb, lua = work / f'{name}.rb', work / f'{name}.lua'
            rb.write_text(source)
            args = ['first', 'two words', '--third'] if name == 'arguments' else []
            oracle = run([ruby, rb, *args]); assert_ok(oracle, f'CRuby {name}')
            compiled = run([COMPILER, rb, '-o', lua]); assert_ok(compiled, f'compile {name}')
            for vm in vms:
                result = run([vm, lua, *args]); assert_ok(result, f'{Path(vm).name} {name}')
                if result.stdout != oracle.stdout:
                    raise AssertionError(f'{Path(vm).name} {name}\nRuby: {oracle.stdout!r}\nLua:  {result.stdout!r}')
                executions += 1
        interop = work / 'interop.rb'
        interop.write_text('puts Lua.require("math").sqrt(81).to_i\nputs Lua.global("type").call("kah")\n')
        native_lua = work / 'interop.lua'
        assert_ok(run([COMPILER, interop, '-o', native_lua]), 'compile Lua interop')
        for vm in vms:
            result = run([vm, native_lua]); assert_ok(result, f'{vm} Lua interop')
            assert result.stdout == b'9\nstring\n', result.stdout
            executions += 1
        overflow = work / 'overflow.rb'
        overflow.write_text('p 4294967296 * 4294967296\n')
        overflow_lua = work / 'overflow.lua'
        assert_ok(run([COMPILER, overflow, '-o', overflow_lua]), 'compile integer overflow')
        for vm in vms:
            result = run([vm, overflow_lua])
            assert result.returncode != 0 and b'RangeError' in result.stderr, (vm, result.stdout, result.stderr)
        engine = work / 'engine.rb'
        engine.write_text('if RUBY_ENGINE == "kah"; puts "kah"; else; puts "wrong"; end\nputs RUBY_ENGINE\n')
        engine_lua = work / 'engine.lua'
        assert_ok(run([COMPILER, engine, '-o', engine_lua]), 'compile engine guard')
        for vm in vms:
            result = run([vm, engine_lua]); assert_ok(result, 'engine guard')
            assert result.stdout == b'kah\nkah\n', result.stdout
        libraries = work / 'libraries'
        libraries.mkdir()
        helper = libraries / 'helper.rb'
        helper.write_text('$loads = ($loads || 0) + 1\ndef loaded_answer(n)\n n * 3\nend\n')
        imports = work / 'imports.rb'
        imports.write_text('$loads = 0\nif false; require_relative "libraries/helper"; end\np(require_relative "libraries/helper")\np(require_relative "libraries/helper")\np $loads, loaded_answer(14)\n')
        imports_lua = work / 'imports.lua'
        oracle = run([ruby, imports]); assert_ok(oracle, 'CRuby local requires')
        assert_ok(run([COMPILER, imports, '-o', imports_lua]), 'compile local requires')
        for vm in vms:
            result = run([vm, imports_lua]); assert_ok(result, 'local requires')
            assert result.stdout == oracle.stdout, (vm, result.stdout, oracle.stdout)
        named = work / 'named_import.rb'
        named.write_text('require "helper"\np loaded_answer(14)\n')
        named_lua = work / 'named_import.lua'
        assert_ok(run([COMPILER, '-I', libraries, named, '-o', named_lua]), 'compile -I require')
        for vm in vms:
            result = run([vm, named_lua]); assert_ok(result, 'named require')
            assert result.stdout == b'42\n', result.stdout
        (libraries / 'a.rb').write_text('$order << :a\nrequire_relative "b"\n')
        (libraries / 'b.rb').write_text('$order << :b\nrequire_relative "a"\n')
        cycle = work / 'cycle.rb'
        cycle.write_text('$order = []\nrequire_relative "libraries/a"\np $order\n')
        cycle_lua = work / 'cycle.lua'
        oracle = run([ruby, cycle]); assert_ok(oracle, 'CRuby cyclic require')
        assert_ok(run([COMPILER, cycle, '-o', cycle_lua]), 'compile cyclic require')
        for vm in vms:
            result = run([vm, cycle_lua]); assert_ok(result, 'cyclic require')
            assert result.stdout == oracle.stdout, (vm, result.stdout, oracle.stdout)
        child_exit = work / 'child_exit.rb'
        child_exit.write_text('Lua.global("os").exit(7)\n')
        for vm in vms:
            result = run([COMPILER, f'--lua={vm}', '-E', child_exit])
            assert result.returncode == 7, (vm, result.returncode, result.stderr)
        for name, source in REFUSALS.items():
            rb, lua = work / f'{name}.rb', work / f'{name}.lua'
            rb.write_text(source)
            result = run([COMPILER, rb, '-o', lua])
            assert result.returncode != 0 and not lua.exists(), (name, result.stderr)
            assert str(rb).encode() in result.stderr, (name, result.stderr)
        rb, output = work / 'cli.rb', work / 'cli.lua'
        rb.write_text('puts "kah"\np ARGV\n')
        output.write_text('unique user data\n')
        refused = run([COMPILER, rb, '-o', output])
        assert refused.returncode != 0 and output.read_text() == 'unique user data\n'
        assert_ok(run([COMPILER, rb, '-o', output, '--force']), 'force output')
        assert_ok(run([COMPILER, rb, '-o', output]), 'regenerate own output')
        original = rb.read_text()
        assert run([COMPILER, rb, '-o', rb, '--force']).returncode != 0
        assert rb.read_text() == original
        standalone = work / 'kah'
        shutil.copyfile(COMPILER.resolve(), standalone)
        standalone.chmod(0o755)
        standalone_env = os.environ.copy()
        standalone_env['PATH'] = '/usr/bin:/bin'
        standalone_lua = work / 'standalone.lua'
        assert_ok(run([standalone, rb, '-o', standalone_lua], env=standalone_env), 'standalone compiler without Ruby or builtin files')
        for vm in vms:
            result = run([vm, standalone_lua]); assert_ok(result, 'standalone output')
            assert result.stdout == b'kah\n[]\n', result.stdout
        inline = work / 'inline.lua'
        assert_ok(run([COMPILER, '-e', 'puts 42', '-o', inline]), 'inline output')
        assert inline.exists()
        stdout = run([COMPILER, rb, '-S']); assert_ok(stdout, 'Lua stdout')
        assert stdout.stdout.startswith(b'-- Generated by Kah:')
        for vm in vms:
            result = run([COMPILER, f'--lua={vm}', '-E', rb, 'one', 'two words'])
            assert_ok(result, f'CLI run {vm}')
            assert result.stdout == b'kah\n["one", "two words"]\n', result.stdout
        missing = run([COMPILER, '--lua=/nonexistent/kah-lua', '-E', rb])
        assert missing.returncode == 127, missing.stderr
        emitted = run([COMPILER, '--target=lua', rb, '-S'])
        assert_ok(emitted, 'explicit Lua target')
        assert emitted.stdout == stdout.stdout
        native = run([BOOTSTRAP, '-e', 'puts 42', '-S'])
        assert_ok(native, 'native C backend regression')
        assert b'Generated by Kah' not in native.stdout and b'int main(' in native.stdout
        for options in [['--emit-types'], ['--int-overflow=promote'], ['--target=unknown']]:
            assert run([COMPILER, *options, rb, '-S']).returncode != 0, options
    print(f'PASS: {len(CASES)} CRuby differential programs, {executions} VM executions, {len(REFUSALS)} refusals, CLI and native backend checks')
    print('VMs: ' + ', '.join(Path(vm).name for vm in vms))


if __name__ == '__main__':
    main()
