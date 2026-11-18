# Combine typed Nelua modules and generated Prism declarations into one unit.
prism, bindings, platform, output = ARGV
source = File.read(prism).sub('-- @prism-bindings', File.read(bindings))
File.write(output, source + "\n" + File.read(platform))
