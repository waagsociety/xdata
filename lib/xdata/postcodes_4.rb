#!/usr/bin/env ruby

require 'zlib'
require 'base64'
require 'stringio'

class PC4
  data = File.read(File.dirname(__FILE__) + "/pc4.b64")
  @@pc = Marshal.load(Zlib::GzipReader.new(StringIO.new(Base64.decode64(data))).read)
  data = nil
  def self.lookup(str)
    str = str.gsub(/[^\d]/,'').downcase
    bbox = @@pc[str]
    return [[bbox[0][0].unpack('e')[0], bbox[0][1].unpack('e')[0]],[bbox[1][0].unpack('e')[0], bbox[1][1].unpack('e')[0]]] if bbox
    nil
  end
end

#
#
# if ARGV[0]
#   h = PC4.lookup ARGV[0]
#   if(h)
#     puts "bl: #{h[0][0]}, #{h[0][1]}\ntr: #{h[1][0]}, #{h[1][1]}"
#   else
#     STDERR.puts "'#{ARGV[0]}' does not seem to be a valid postcode."
#     exit(1)
#   end
# end
# # puts PC.lookup('1012 CR')
#
#
