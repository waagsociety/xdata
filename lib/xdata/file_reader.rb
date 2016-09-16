require 'csv'
require 'geo_ruby'
require 'geo_ruby/shp'
require 'geo_ruby/geojson'
require 'charlock_holmes'
require 'tmpdir'

# feature = source_factory.point(1266457.58, 230052.50)
# feature = RGeo::Feature.cast(feature,:factory => wgs84_factory, :project => true)

module XData

  class FileReader

    RE_Y = /lat|(y.*coord)|(y.*pos.*)|(y.*loc(atie|ation)?)/i
    RE_X = /lon|lng|(x.*coord)|(x.*pos.*)|(x.*loc(atie|ation)?)/i
    RE_GEO = /^(geom(etry)?|location|locatie|coords|coordinates)$/i
    RE_NAME = /(title|titel|naam|name)/i
    RE_A_NAME = /^(naam|name|title|titel)$/i

    attr_reader :file, :content,:params

    def initialize(pars)
      @params = pars
      
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
          else
            raise "Unknown or unsupported file type: #{ext}."
        end
      end

      @params[:rowcount] = @content.length
      get_fields unless @params[:fields]
      guess_name unless @params[:name]
      guess_srid unless @params[:srid]
      find_unique_field  unless @params[:unique_id]
      get_address unless @params[:hasaddress]
      
      findExtends unless @params[:bounds]
      
      set_id_name
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

    def set_id_name
      count = 123456
      if @params[:unique_id]
        @content.each do |h|
          h[:properties][:id] = h[:properties][:data][@params[:unique_id]]
          h[:properties][:title] = h[:properties][:data][@params[:name]] if @params[:name]
        end
      else
        @params[:unique_id] = :csdk_gen
        # @params[:fields] << :csdk_gen
        # @params[:original_fields] << :csdk_gen
        # @params[:alternate_fields][:csdk_gen] = :csdk_gen
        @content.each do |h|
          h[:properties][:id] = "cg_#{count}"
          h[:properties][:title] = h[:properties][:data][@params[:name]] if @params[:name]
          count += 1
        end
      end
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
      @content[0][:properties][:data].each_key do |k|
        k = (k.to_sym rescue k) || k
        @params[:fields] << k
        @params[:alternate_fields][k] = k
      end
    end

    def guess_srid
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
      return unless @params[:hasgeometry]
      geometries = []
      @content.each do |o|
        o[:geometry][:type] = 'MultiPolygon' if o[:geometry][:type] == 'Multipolygon'
        geometries << Geometry.from_geojson(o[:geometry].to_json)
      end
      geom = GeometryCollection.from_geometries(geometries, (@params[:srid] || '4326'))
      @params[:bounds] = geom.bounding_box()
    end
    

    def find_geometry(xfield=nil, yfield=nil)
      delete_column = (@params[:keep_geom] != true)
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
        @params[:hasgeometry] = [xfield,yfield].to_s
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
        @params[:hasgeometry] = "[#{xfield}]"
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

    def read_csv(path)
      @file = path
      c=''
      File.open(path, "r:bom|utf-8") do |fd|
        c = fd.read
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

    def read_json(path)
      @content = []
      @file = path
      raw = ''
      File.open(path, "r:bom|utf-8") do |fd|
        raw = fd.read
      end
      hash = XData::parse_json(raw)

      if hash.is_a?(Hash) and hash[:type] and (hash[:type] == 'FeatureCollection')
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

    def read_shapefile(path)

      @content = []
      @file = path

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

    def read_csdk(path)
      h = Marshal.load(File.read(path))
      @params = h[:config]
      @content = h[:content]
    end

    def read_zip(path)
      begin
        Dir.mktmpdir("xdfi_#{File.basename(path).gsub(/\A/,'')}") do |dir|
          raise XData::Exception.new("Error unzipping #{path}.", {:originalfile => path}, __FILE__, __LINE__) if not system "unzip '#{path}' -d '#{dir}' > /dev/null 2>&1"
          if File.directory?(dir + '/' + File.basename(path).chomp(File.extname(path)))
            dir = dir + '/' + File.basename(path).chomp(File.extname(path) )
          end
          Dir.foreach(dir) do |f|
            next if f =~ /^\./
            case File.extname(f)
              when /\.(geo)?json/i
                read_json(dir+'/'+f)
                return
              when /\.shp/i
                read_shapefile(dir+'/'+f)
                return
              when /\.csv|tsv/i
                read_csv(dir+'/'+f)
                return
            end
          end
        end
      rescue Exception => e
        raise XData::Exception.new(e.message, {:originalfile => path}, __FILE__, __LINE__)
      end
      raise XData::Exception.new("Could not proecess file #{path}", {:originalfile => path}, __FILE__, __LINE__)
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

