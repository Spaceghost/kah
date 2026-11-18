# Generate Nelua declarations/accessors from Prism's public C AST schema.
# This generator emits Nelua only. The C declarations remain Prism's own.
header = File.binread(ARGV.fetch(0)).gsub(%r{/\*.*?\*/}m, '')
records = []
header.scan(/typedef struct (pm_\w+_node)\s*\{(.*?)\}\s*(pm_\w+_node_t);/m) do |tag, body, type|
  fields = []
  body.each_line do |line|
    match = /^\s*((?:struct\s+)?\w+)\s*(\*+)?\s*(\w+)\s*;/.match(line)
    fields << [(match[1] + (match[2] ? " " + match[2] : "")).strip, match[3]] if match
  end
  records << [tag, type, fields]
end
abort 'Prism AST schema was not recognized' if records.empty?

def nelua_type(type)
  return 'pointer' if type.include?('*') && type.match?(/\A(?:struct )?pm_(?:\w+_)?node(?:_t)? \*\z/)
  {'pm_node_t'=>'Node', 'struct pm_node'=>'Node', 'pm_node_list_t'=>'NodeList',
   'struct pm_node_list'=>'NodeList', 'pm_constant_id_t'=>'uint32', 'pm_string_t'=>'PrismString',
   'pm_integer_t'=>'PrismInteger', 'double'=>'cdouble', 'uint32_t'=>'uint32',
   'uint8_t'=>'uint8', 'int32_t'=>'int32', 'bool'=>'boolean'}[type]
end
puts '-- Generated from the pinned Prism public header by tools/gen_kah_prism.rb.'
records.each do |tag, type, fields|
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  constant=tag.upcase
  puts "local #{constant}: uint16 <cimport,nodecl>"
  declarations=fields.filter_map { |t, f| nt=nelua_type(t); "#{f}:#{nt}" if nt }
  puts "local #{name} <cimport '#{type}',nodecl,cincomplete> = @record{#{declarations.join(',')}}"
end
puts 'local function kind_name(node:*Node):cstring'
records.each do |tag, type, fields|
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then return '#{name}' end"
end
puts "  return 'UnknownNode'\nend"

puts 'local function field_ref(node:*Node,field:string):*Node'
records.each do |tag, type, fields|
  refs=fields.select { |t,f| nelua_type(t)=='pointer' }
  next if refs.empty?
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then"
  puts "    local n=(@*#{name})(node)"
  refs.each { |t,f| puts "    if field == '#{f}' then return (@*Node)(n.#{f}) end" }
  puts '  end'
end
puts "  return nilptr\nend"
puts 'local function field_list(node:*Node,field:string):*NodeList'
records.each do |tag, type, fields|
  lists=fields.select { |t,f| nelua_type(t)=='NodeList' }
  next if lists.empty?
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then"
  puts "    local n=(@*#{name})(node)"
  lists.each { |t,f| puts "    if field == '#{f}' then return &n.#{f} end" }
  puts '  end'
end
puts "  return nilptr\nend"
puts 'local function field_integer(node:*Node,field:string):clong'
puts "  if field == 'flags' then return node.flags end"
records.each do |tag,type,fields|
  ints=fields.select { |t,f| %w[uint32_t uint8_t int32_t bool].include?(t) }
  next if ints.empty?
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then"
  puts "    local n=(@*#{name})(node)"
  ints.each { |t,f| puts "    if field == '#{f}' then return clong(n.#{f}) end" }
  puts '  end'
end
puts "  return 0\nend"
puts 'local function field_constant(node:*Node,field:string):uint32'
records.each do |tag,type,fields|
  constants=fields.select { |t,f| t=='pm_constant_id_t' }
  next if constants.empty?
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then"
  puts "    local n=(@*#{name})(node)"
  constants.each { |t,f| puts "    if field == '#{f}' then return n.#{f} end" }
  puts '  end'
end
puts "  return 0\nend"
puts 'local function field_string(node:*Node,field:string):*PrismString'
records.each do |tag,type,fields|
  strings=fields.select { |t,f| t=='pm_string_t' }
  next if strings.empty?
  name=tag.sub('pm_', '').split('_').map(&:capitalize).join
  puts "  if node.type == #{tag.upcase} then"
  puts "    local n=(@*#{name})(node)"
  strings.each { |t,f| puts "    if field == '#{f}' then return &n.#{f} end" }
  puts '  end'
end
puts "  return nilptr\nend"
