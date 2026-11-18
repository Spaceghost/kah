# A language boundary check: executable compiler logic is Ruby; native code is Nelua.
require 'json'
root = File.expand_path('..', __dir__)
paths = Dir.glob(File.join(root, 'compiler', '**', '*')).select { |p| File.file?(p) }
errors = []
paths.each do |path|
  extension = File.extname(path)
  errors << "handwritten C/C++ in compiler implementation: #{path}" if %w[.c .h .cc .cpp .hpp].include?(extension)
  source = File.read(path)
  errors << "inline C escape in #{path}" if source.include?('ffi_source') || source.match?(/cinclude\s*\[\[/)
end
binary = ARGV[0]
if binary && File.file?(binary)
  symbols = IO.popen(['nm', '-g', binary], &:read)
  %w[sp_parse_file codegen_program codegen_lua_program].each do |name|
    errors << "legacy compiler linked into Kah: #{name}" if symbols.match?(/\s#{Regexp.escape(name)}$/)
  end
  %w[kah_native_parse kah_native_run kah_native_string pm_parse].each do |name|
    errors << "missing native/Prism symbol: #{name}" unless symbols.match?(/\s#{Regexp.escape(name)}$/)
  end
end
abort errors.join("\n") unless errors.empty?
report = {
  'implementation' => paths.map { |p| p.delete_prefix(root + '/') }.sort,
  'handwritten_c_in_compiler' => 0,
  'logic' => 'Ruby compiled by Spinel',
  'native' => 'Nelua compiled to an object file',
  'external_c_dependencies' => ['Prism parser', 'Spinel generated-code runtime', 'system C library'],
  'bootstrap' => 'Inherited Spinel sources are retained for building the Ruby compiler, not linked into the Kah executable.',
  'generated_c' => ['Spinel output from compiler/kah.rb', 'Nelua output from compiler/native/*.nelua']
}
puts JSON.pretty_generate(report)
