require 'json'
require 'i18n'
require 'proj4'
require 'net/http'
require 'net/https'

class String
  def remove_non_ascii
    self.encode( "UTF-8", "binary", :invalid => :replace, :undef => :replace, :replace => '§')
  end
  def starts_with?(aString)
    index(aString) == 0
  end
end

class Object
  def deep_copy
    Marshal.load(Marshal.dump(self))
  end
  def blank?
    return false if self.class == Symbol
    self.nil? or (self.class==String and self.strip == '') or (self.respond_to?(:empty?) ? self.empty? : false)
  end
end



module XData
  ::I18n.enforce_available_locales = false
  RD_P = Proj4::Projection.new('+proj=sterea +lat_0=52.15616055555555 +lon_0=5.38763888888889 +k=0.9999079 +x_0=155000 +y_0=463000 +ellps=bessel +units=m +no_defs')
  LL_P = Proj4::Projection.new('+proj=longlat +ellps=WGS84 +datum=WGS84 +no_defs')
  
  def toPolygon(twopoints)
    lon1 = twopoints[0].lon
    lat1 = twopoints[0].lat
    lon2 = twopoints[1].lon
    lat2 = twopoints[1].lat
    
    if lon1.between?(-7000.0,300000.0) and lat1.between?(289000.0,629000.0)
      # Simple minded check for Dutch new rd system
      a = XData.rd_to_wgs84(lon1,lat1)
      lon1 = a[0]; lat1 = a[1]
      a = XData.rd_to_wgs84(lon2,lat2)
      lon2 = a[0]; lat2 = a[1]
    end
    return { type: 'Polygon', coordinates: [[lon1,lat1], [lon1,lat2], [lon2,lat2], [lon2,lat1], [lon1,lat1]] }
  end

  def self.rd_to_wgs84(x,y)
    srcPoint = Proj4::Point.new(x, y)
    dstPoint = RD_P.transform(LL_P, srcPoint)
    [dstPoint.lon * (180 / Math::PI), dstPoint.lat * (180 / Math::PI)]
  end

  def self.headers(url)
    begin
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      if url.scheme == 'https'
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      return http.head(uri.path.blank? ? "/" : uri.path).to_hash
    rescue
    end
    nil
  end

  # for debugging purposes...
  def jsonlog(o)
    STDERR.puts JSON.pretty_generate({ o.class.to_s => o })
  end

  class Exception < ::Exception
    def initialize(message,parms=nil,srcfile=nil,srcline=nil)
      if parms and srcfile and srcline
        file = File.basename( parms[:originalfile] ? parms[:originalfile] : ( parms[:file_path] || '-' ) )
        m = "#{Time.now.strftime("%b %M %Y, %H:%M")}; XData, processing file: #{file}\n Exception in #{File.basename(srcfile)}, #{srcline}\n #{message}"
      else
        m = "#{Time.now.strftime("%b %M %Y, %H:%M")}; XData Exception: #{message}"
      end
      super(m)
      $stderr.puts(m) if parms and parms[:verbose]
    end
  end

  def self.parse_json(str)
    begin
      return str.blank? ? {} : JSON.parse(str, symbolize_names: true)
    rescue Exception => e
      raise XData::Exception.new("#{e.message}; input: #{str}")
    end
  end

end



