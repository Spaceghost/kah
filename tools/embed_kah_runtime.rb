# A Ruby literal embedded by Spinel: no runtime support files are needed.
source = File.binread(ARGV.fetch(0))
puts 'module KahRuntime'
puts "  SOURCE = #{source.dump}"
puts 'end'
