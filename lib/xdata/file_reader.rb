require 'csv'
require 'cgi'
require 'tmpdir'
require 'feedjira'
require 'geo_ruby'
require 'tempfile'
require 'geo_ruby/shp'
require 'geo_ruby/geojson'
require 'charlock_holmes'

require 'open-uri'

# wgs84_factory = RGeo::Geographic.spherical_factory(:srid => 4326, :proj4 => wgs84_proj4, :coord_sys => wgs84_wkt)

# feature = rd_factory.point(131712.93,456415.20)
# feature = RGeo::Feature.cast(feature,:factory => wgs84_factory, :project => true)

# factory = RGeo::Geographic.projected_factory(:projection_proj4 => '+proj=sterea +lat_0=52.15616055555555 +lon_0=5.38763888888889 +k=0.9999079 +x_0=155000 +y_0=463000 +ellps=bessel +units=m +no_defs ')
# rd_factory = RGeo::Geographic.spherical_factory(:srid => 28992, :proj4 => amersfoort-rd-new)
# curved_factory = RGeo::Geographic.spherical_factory(:srid => 4326)

module XData

  class FileReader

    RE_Y = /lat|(y.*coord)|(y.*pos.*)|(y.*loc(atie|ation)?)/i
    RE_X = /lon|lng|(x.*coord)|(x.*pos.*)|(x.*loc(atie|ation)?)/i
    RE_GEO = /^(geom(etry)?|location|locatie|coords|coordinates)$/i
    RE_NAME = /(title|titel|naam|name)/i
    RE_A_NAME = /^(naam|name|title|titel)$/i

    attr_reader :file, :content,:params

    def fillOut
      @params[:rowcount] = @content.length
      get_fields          unless @params[:fields]
      guess_name          unless @params[:name]
      guess_srid          unless @params[:srid]
      find_unique_field   unless @params[:unique_id]
      get_address         unless @params[:hasaddress]
      findExtends         unless @params[:bounds]
    end
    
    def odata_json(url)
      if url =~ /\/ODataFeed\//
        uri = URI.parse(url)
        return url + '?$format=json' if uri.query.nil?
        pars = CGI.parse(uri.query)
        return url if pars["$format"]
        return url + '&$format=json'
      end
      return url
    end

    def download()
      data = ''
      if @params[:file_path] =~ /\/ODataFeed\//
        open(odata_json(@params[:file_path])) do |f|
          data = XData::parse_json(f.read)
          read_json(nil,data)
        end
      else
        open(@params[:file_path]) do |f|
          data = f.read
        end
        if @params[:file_path] =~ /\.csv$/i 
          read_csv(nil,data)
        elsif @params[:file_path] =~ /\.zip$/i 
          read_zip(nil,data)
        elsif data =~ /^\s*<\?xml/
          read_xml(nil,data)
        else
          begin 
            data = XData::parse_json(data)
            read_json(nil,data)
          rescue XData::Exception
            return
          end
        end
      end
      fillOut
    end
    

    def initialize(pars)
      @params = pars
      
      if @params[:file_path] =~ /^http(s)?:\/\/.+/
        download
      else
        file_path = File.expand_path(@params[:file_path])
        if File.extname(file_path) == '.xdata'
          read_xdata(file_path)
        else
          ext = @params[:originalfile] ? File.extname(@params[:originalfile]) : File.extname(file_path)
          case ext
            when /\.zip/i
              read_zip(file_path)
            when /\.(geo)?json/i
              read_json(file_path)
            when /\.shp/i
              read_shapefile(file_path)
            when /\.csv|tsv/i
              read_csv(file_path)
            when /\.xdata/i
              read_xdata(file_path)
            when /\.xml/i
              read_xml(file_path)
            else
              raise "Unknown or unsupported file type: #{ext}."
          end
        end
      end
      fillOut
    end

    def get_address
      pd = pc = hn = ad = false
      @params[:housenumber] = nil
      @params[:hasaddress] = 'unknown'
      @params[:postcode] = nil
      @params[:fields].reverse.each do |f|
        pc = f if ( f.to_s =~ /^(post|zip|postal)code.*/i )
        hn = f if ( f.to_s =~ /huisnummer|housenumber|(house|huis)(nr|no)|number/i)
        ad = f if ( f.to_s =~ /address|street|straat|adres/i)
      end
      if pc and (ad or hn)
        @params[:hasaddress] = 'certain'
      end
      @params[:postcode] = pc
      @params[:housenumber] = hn ? hn : ad
    end

    def find_unique_field
      fields = {}
      @params[:unique_id] = nil
      @content.each do |h|
        h[:properties][:data].each do |k,v|
          fields[k] = Hash.new(0) if fields[k].nil?
          fields[k][v] += 1
        end
      end

      fields.each_key do |k|
        if fields[k].length == @params[:rowcount]
          @params[:unique_id] = k
          break
        end
      end

    end

    def guess_name
      @params[:name] = nil
      @params[:fields].reverse.each do |k|
        if(k.to_s =~ RE_A_NAME)
          @params[:name] = k
          return
        end
        if(k.to_s =~ RE_NAME)
          @params[:name] = k
        end
      end
    end

    def get_fields
      @params[:fields] = []
      @params[:alternate_fields] = {}
      return if @content.blank?
      @content[0][:properties][:data].each_key do |k|
        k = (k.to_sym rescue k) || k
        @params[:fields] << k
        @params[:alternate_fields][k] = k
      end
    end

    def guess_srid
      return if @content.blank?
      return unless @content[0][:geometry] and @content[0][:geometry].class == Hash
      @params[:srid] = 4326
      g = @content[0][:geometry][:coordinates]
      if(g)
        while g[0].is_a?(Array)
          g = g[0]
        end
        lon = g[0]
        lat = g[1]
        if lon.between?(-7000.0,300000.0) and lat.between?(289000.0,629000.0)
          # Simple minded check for Dutch new rd system
          @params[:srid] = 28992
        end
      else

      end
    end

    def find_col_sep(f)
      a = f.gets
      b = f.gets
      [";","\t","|"].each do |s|
        return s if (a.split(s).length == b.split(s).length) and b.split(s).length > 1
      end
      ','
    end

    def is_wkb_geometry?(s)
      begin
        f = GeoRuby::SimpleFeatures::GeometryFactory::new
        p = GeoRuby::SimpleFeatures::HexEWKBParser.new(f)
        p.parse(s)
        g = f.geometry
        return g.srid,g.as_json[:type],g
      rescue => e
      end
      nil
    end

    def is_wkt_geometry?(s)
      begin
        f = GeoRuby::SimpleFeatures::GeometryFactory::new
        p = GeoRuby::SimpleFeatures::EWKTParser.new(f)
        p.parse(s)
        g = f.geometry
        return g.srid,g.as_json[:type],g
      rescue => e
      end
      nil
    end

    GEOMETRIES = ["point", "multipoint", "linestring", "multilinestring", "polygon", "multipolygon"]
    def is_geo_json?(s)
      return nil if s.class != Hash
      begin
        if GEOMETRIES.include?(s[:type].downcase)
          srid = 4326
          if s[:crs] and s[:crs][:properties]
            if s[:crs][:type] == 'OGC'
              urn = s[:crs][:properties][:urn].split(':')
              srid = urn.last.to_i if (urn[4] == 'EPSG')
            elsif s[:crs][:type] == 'EPSG'
              srid = s[:crs][:properties][:code]
            end
          end
          return srid,s[:type],s
        end
      rescue Exception=>e
      end
      nil
    end

    def geom_from_text(coords)
      # begin
      #   a = factory.parse_wkt(coords)
      # rescue
      # end

      if coords =~ /^(\w+)(.+)/
        if GEOMETRIES.include?($1.downcase)
          type = $1.capitalize
          coor = $2.gsub('(','[').gsub(')',']')
          coor = coor.gsub(/([-+]?[0-9]*\.?[0-9]+)\s+([-+]?[0-9]*\.?[0-9]+)/) { "[#{$1},#{$2}]" }
          coor = JSON.parse(coor)
          return { :type => type,
            :coordinates => coor }
        end
      end
      {}
    end
    
    def findExtends
      geometries = []
      if @params[:hasgeometry]
        @content.each do |o|
          o[:geometry][:type] = 'MultiPolygon' if o[:geometry][:type] == 'Multipolygon'
          geometries << Geometry.from_geojson(o[:geometry].to_json)
        end
        geom = GeometryCollection.from_geometries(geometries, (@params[:srid] || '4326'))
        @params[:bounds] = XData.toPolygon(geom.bounding_box())
      elsif @params[:postcode]
        pc = @params[:postcode].to_sym
        @content.each do |o|
          p2 = PC4.lookup(o[:properties][:data][pc])
          if p2
            geometries << GeoRuby::SimpleFeatures::Point.from_coordinates(p2[0], (@params[:srid] || '4326'))
            geometries << GeoRuby::SimpleFeatures::Point.from_coordinates(p2[1], (@params[:srid] || '4326'))
          end
        end
        geom = GeometryCollection.from_geometries(geometries, (@params[:srid] || '4326'))
        @params[:bounds] = XData.toPolygon(geom.bounding_box())
      end
    end
    

    def find_geometry(xfield=nil, yfield=nil)
      delete_column = (@params[:keep_geom] != true)
      return if @content.blank?
      unless(xfield and yfield)
        @params[:hasgeometry] = nil
        xs = true
        ys = true

        @content[0][:properties][:data].each do |k,v|
          next if k.nil?

          if k.to_s =~ RE_GEO
            srid,g_type = is_wkb_geometry?(v)
            if(srid)
              @params[:srid] = srid
              @params[:geometry_type] = g_type
              @content.each do |h|
                a,b,g = is_wkb_geometry?(h[:properties][:data][k])
                h[:geometry] = g
                h[:properties][:data].delete(k) if delete_column
              end
              @params[:hasgeometry] = k
              return true
            end

            srid,g_type = is_wkt_geometry?(v)
            if(srid)
              @params[:srid] = srid
              @params[:geometry_type] = g_type
              @content.each do |h|
                a,b,g = is_wkt_geometry?(h[:properties][:data][k])
                h[:geometry] = g
                h[:properties][:data].delete(k) if delete_column
              end
              @params[:hasgeometry] = k
              return true
            end

            srid,g_type = is_geo_json?(v)
            if(srid)
              @params[:srid] = srid
              @params[:geometry_type] = g_type
              @content.each do |h|
                h[:geometry] = h[:properties][:data][k]
                h[:properties].delete(k) if delete_column
              end
              @params[:hasgeometry] = k
              return true
            end

          end

          hdc = k.to_s.downcase
          if hdc == 'longitude' or hdc == 'lon' or hdc == 'x'
            xfield=k; xs=false
          end
          if hdc == 'latitude' or hdc == 'lat' or hdc == 'y'
            yfield=k; ys=false
          end
          xfield = k if xs and (hdc =~ RE_X)
          yfield = k if ys and (hdc =~ RE_Y)
        end
      end

      if xfield and yfield and (xfield != yfield)
        @params[:hasgeometry] = [xfield,yfield]
        @content.each do |h|
          h[:properties][:data][xfield] = h[:properties][:data][xfield] || ''
          h[:properties][:data][yfield] = h[:properties][:data][yfield] || ''
          h[:geometry] = {:type => 'Point', :coordinates => [h[:properties][:data][xfield].gsub(',','.').to_f, h[:properties][:data][yfield].gsub(',','.').to_f]}
          h[:properties][:data].delete(yfield) if delete_column
          h[:properties][:data].delete(xfield) if delete_column
        end
        @params[:geometry_type] = 'Point'
        @params[:fields].delete(xfield) if @params[:fields] and delete_column
        @params[:fields].delete(yfield) if @params[:fields] and delete_column
        return true
      elsif (xfield and yfield)
        # factory = ::RGeo::Cartesian.preferred_factory()
        @params[:hasgeometry] = [xfield]
        @content.each do |h|
          h[:geometry] = geom_from_text(h[:properties][:data][xfield])
          h[:properties][:data].delete(xfield) if h[:geometry] and delete_column
        end
        @params[:geometry_type] = ''
        @params[:fields].delete(xfield) if @params[:fields] and delete_column
        return true
      end
      false
    end

    def read_csv(path, c = nil)
      if path 
        File.open(path, "r:bom|utf-8") do |fd|
          c = fd.read
        end
      end

      unless @params[:utf8_fixed]
        detect = CharlockHolmes::EncodingDetector.detect(c)
        c =	CharlockHolmes::Converter.convert(c, detect[:encoding], 'UTF-8') if detect
      end
      c = c.force_encoding('utf-8')
      c = c.gsub(/\r\n?/, "\n")
      @content = []
      @params[:colsep] = find_col_sep(StringIO.new(c)) unless @params[:colsep]
      csv = CSV.new(c, :col_sep => @params[:colsep], :headers => true, :skip_blanks =>true)
      csv.header_convert { |h| h.blank? ? '_' : h.strip.gsub(/\s+/,'_')  }
      csv.convert { |h| h ? h.strip : '' }
      index = 0
      begin
        csv.each do |row|
          r = row.to_hash
          h = {}
          r.each do |k,v|
            h[(k.to_sym rescue k) || k] = v
          end
          @content << {properties: {data: h} }
          index += 1
        end
      rescue => e
        raise XData::Exception.new("Read CSV; line #{index}; #{e.message}")
      end
      find_geometry
    end

    def read_json(path, hash=nil)
      
      STDERR.puts hash.class if hash
      
      @content = []
      if path
        data = ''
        File.open(path, "r:bom|utf-8") do |fd|
          data = fd.read
        end
        hash = XData::parse_json(data)
      end
      
      if hash.is_a?(Hash) and hash[:'odata.metadata']
        read_odata(hash)
      elsif hash.is_a?(Hash) and hash[:type] and (hash[:type] == 'FeatureCollection')
        # GeoJSON
        hash[:features].each do |f|
          f.delete(:type)
          f[:properties] = {data: f[:properties]}
          @content << f
        end
        @params[:hasgeometry] = 'GeoJSON'

      else
        # Free-form JSON
        val,length = nil,0
        if hash.is_a?(Array)
           # one big array
           val,length = hash,hash.length
        else
          hash.each do |k,v|
            if v.is_a?(Array)
              # the longest array value in the Object
              val,length = v,v.length if v.length > length
            end
          end
        end

        if val
          val.each do |h|
            @content << { :properties => {:data => h} }
          end
        end
        find_geometry
      end
    end

    def srid_from_prj(str)
      begin
        connection = Faraday.new :url => "http://prj2epsg.org"
        resp = connection.get('/search.json', {:mode => 'wkt', :terms => str})
        if resp.status.between?(200, 299)
          resp = XData::parse_json resp.body
          @params[:srid] = resp[:codes][0][:code].to_i
        end
      rescue
      end
    end
  
    def parseODataMeta(md)
      @params[:md] = {} if @params[:md].nil?
      @params[:md][:title] = md[:Title]
      @params[:md][:identifier] = md[:Identifier]
      @params[:md][:description] = md[:Description]
      @params[:md][:abstract] = md[:ShortDescription]
      @params[:md][:modified] = md[:Modified]
      @params[:md][:temporal] = md[:Period]
      @params[:md][:publisher] = md[:Source]
      @params[:md][:accrualPeriodicity] = md[:Frequency]
      @params[:md][:language] = md[:Language]
    end
  
    def parseODataFields(props)
      rank=1
      @params[:md] = {} if @params[:md].nil?
      props.each do |p|
        @params[:md]["fieldUnit.#{rank}".to_sym] = p[:Unit]
        @params[:md]["fieldDescription.#{rank}".to_sym] = p[:Description]
        @params[:md]["fieldLabel.#{rank}".to_sym] = p[:Key]
        rank += 1
      end
    end

    def read_odata(h)
      @content = []
      @params[:odata] = {}
      links = h[:value]
      links.each do |l|
        @params[:odata][l[:name].to_sym] = l[:url]
      end
      
      begin
        open(odata_json(@params[:odata][:TableInfos])) do |f|
          md = XData::parse_json(f.read)[:value]
          parseODataMeta(md[0])
        end

        open(odata_json(@params[:odata][:DataProperties])) do |f|
          props = XData::parse_json(f.read)[:value]
          parseODataFields(props)
        end

        open(odata_json(@params[:odata][:TypedDataSet])) do |f|
          c = XData::parse_json(f.read)[:value]
          c.each do |h|
            @content << { :properties => {:data => h} }
          end
        end

      rescue OpenURI::HTTPError => e
        STDERR.puts e.message
      end

      find_geometry
    end
    
    
    def read_shapefile(path)

      @content = []

      prj = path.gsub(/.shp$/i,"") + '.prj'
      prj = File.exists?(prj) ? File.read(prj) : nil
      srid_from_prj(prj) if (prj and @params[:srid].nil?)

      @params[:hasgeometry] = 'ESRI Shape'

      GeoRuby::Shp4r::ShpFile.open(path) do |shp|
        shp.each do |shape|
          h = {}
          h[:geometry] = XData::parse_json(shape.geometry.to_json) #a GeoRuby SimpleFeature
          h[:properties] = {:data => {}}
          att_data = shape.data #a Hash
          shp.fields.each do |field|
            s = att_data[field.name]
            s = s.force_encoding('ISO8859-1') if s.class == String
            h[:properties][:data][field.name.to_sym] = s
          end
          @content << h
        end
      end
    end

    def read_xml(path, data=nil)
      if path
        File.open(path, "r:bom|utf-8") do |fd|
          data = fd.read
        end
      end
      begin 
        feed = Feedjira::Feed.parse(data)
        if feed 
          maxlat = -1000
          maxlon = -1000
          minlat = 1000
          minlon = 1000
          doc = Nokogiri::XML data
          a = doc.xpath("//georss:polygon")
          if a.length > 0
            # geometries << GeoRuby::SimpleFeatures::Point..from_latlong(lat, lon)
            a.each do |x|
              # 50.6 3.1 50.6 7.3 53.7 7.3 53.7 3.1 50.6 3.1
              s = x.text.split(/\s+/)
              s.each_slice(2) { |c| 
                maxlat = [maxlat,c[0].to_f].max
                maxlon = [maxlon,c[1].to_f].max
                minlat = [minlat,c[0].to_f].min
                minlon = [minlon,c[1].to_f].min
              }
            end
            @params[:bounds] = { type: 'Polygon', coordinates: [[minlon,minlat], [minlon,maxlat], [maxlon,maxlat], [maxlon,minlat], [minlon,minlat]] }
          end
        end
        # url = feed.entries[0].url
        # Dir.mktmpdir("xdfi_#{File.basename(path).gsub(/\A/,'')}") do |dir|
        #   f = dir + '/' + File.basename(path)
        # end
      rescue Exception => e
        puts e.inspect
        return -1
      end
    end

    def read_xdata(path)
      h = Marshal.load(File.read(path))
      @params = h[:config]
      @content = h[:content]
    end
    
    
    def proces_zipped_dir(d)
      Dir.foreach(d) do |f|

        next if f =~ /^\./
        
        if File.directory?(d + '/' + f)
          return true if proces_zipped_dir(d + '/' + f)
        end

        case File.extname(f)
          when /\.(geo)?json/i
            read_json(d+'/'+f)
            return true
          when /\.shp/i
            read_shapefile(d+'/'+f)
            return true
          when /\.csv|tsv/i
            read_csv(d+'/'+f)
            return true
        end
      end
      return false
    end

    def read_zip(path, data=nil)
      tempfile = nil
      begin
        
        if(data)
          tempfile = Tempfile.new('xdatazip')
          tempfile.write(data)
          path = tempfile.path  
        end

        Dir.mktmpdir("xdfi_#{File.basename(path).gsub(/\A/,'')}") do |dir|
          command = "unzip '#{path}' -d '#{dir}' > /dev/null 2>&1"
          raise XData::Exception.new("Error unzipping #{path}.", {:originalfile => path}, __FILE__, __LINE__) if not system command
          if File.directory?(dir + '/' + File.basename(path).chomp(File.extname(path)))
            dir = dir + '/' + File.basename(path).chomp(File.extname(path) )
          end
          return if proces_zipped_dir(dir)
        end
      rescue Exception => e
        raise XData::Exception.new(e.message, {:originalfile => path}, __FILE__, __LINE__)
      ensure
        tempfile.unlink if tempfile
      end
      raise XData::Exception.new("Could not process file #{path}", {:originalfile => path}, __FILE__, __LINE__)
    end

    def write(path=nil)
      path = @file_path if path.nil?
      path = path + '.xdata'
      begin
        File.open(path,"w") do |fd|
          fd.write( Marshal.dump({:config=>@params, :content=>@content}) )
        end
      rescue
        return nil
      end
      return path
    end

  end

end

