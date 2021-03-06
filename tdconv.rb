# coding: utf-8

# ファイル入力はしない方向で
# 先頭をスキップする処理やヘッダ処理の扱いを各ファイル毎にしないといけないの面倒

require 'rubygems'
require 'optparse'
require 'json'
require 'time'
require 'msgpack'
require 'zlib'
require 'fileutils'

module TreasureData

  # each_line_with_indexが定義されていないので。。
  def $stdin.each_line_with_index()
    i = 0
    $stdin.each_line do | line |
      yield(line, i)
      i = i + 1
    end
  end

  # GZIPの場合はデフォで約4KごとにFlushされるので、それくらいの誤差は許容する方向で。
  # ちまちまFlush(FULL|SYNC)してもいいけど、サイズ大きくなってひどいことになるのでやらない。
  # SplittableWriter -> GzipWriter -> WrapWriter -> STDOut
  #                  --------------->            -> STDErr
  #                                              -> File
  #                                 ↑WroteLen
  #                  ↑writeLen,writeCount
  class SplittableWriter

    class WrapWriter
      def initialize(io)
        @io = io
        @len = 0
      end
      def write(str)
        len = @io.write(str)
        @len += len
        return len
      end
      def close()
        @io.close
      end
      attr_reader :len
    end

    # いろいろひどいので後で直す。後で・・・
    def initialize(io=$stdout, gzip=false, output_dir=nil, filename=nil, limit=10485760)
      @io = io
      @gzip = gzip
      @output_dir = output_dir
      @filename = filename
      @file_count = 0
      @write_count = 0
      @write_len = 0
      @wrote_len = 0
      @limit = limit
    end

    def write2file?()
      return @filename != nil
    end

    def rotate()

      @write_count = 0
      @write_len = 0
      @wrote_len = 0
      @file_count += 1

      # ファイルかどうか？
      if write2file?() then
        FileUtils.mkdir_p(@output_dir.to_s) if not File.exists?(@output_dir.to_s)
        name = File.basename(@filename.to_s, '.*') + "." + @file_count.to_s + File.extname(@filename.to_s)
        name += ".gz" if @gzip
        @inner_writer.close()
        @current_io = open(File.join(@output_dir.to_s, name), "w")
      else
        @current_io = @io
      end
      @current_io = WrapWriter.new(@current_io)

      if @gzip then
        @inner_writer = Zlib::GzipWriter.wrap(@current_io)
      else
        @inner_writer = @current_io 
      end

    end

    def write(str)
      # 書き込もうとした時にサイズ超過している場合はローテーションする
      if @write_count == 0 || (write2file?() && @wrote_len > @limit) then
        rotate()
      end
      # 書き込み
      len = @inner_writer.write(str)
      # 状態更新
      @write_count += 1
      @write_len += len
      @wrote_count = @current_io.len
      return len
    end

    def close()
      if @inner_writer != nil && (@gzip || write2file?()) then
        @inner_writer.close
      end
    end

  end

  class Converter

    class LineParser
      def initialize(opt)
      end
      def opt_parse(opt, converter=nil)
        @time_format = opt[:time_format] if opt[:time_format] != nil
        if opt[:time_value] != nil then
          if @time_format == nil then
            @time_value = opt[:time_value].to_i
          else
            @time_value = Time.strptime(opt[:time_value], @time_format).to_i
          end
        end
        @time_key = opt[:time_key] if opt[:time_key] != nil
      end
      def append_time(obj)
        # オプションに沿って処理を
        if @time_value != nil then
          obj['time'] = @time_value
        elsif @time_key != nil then
          # キーの存在チェック
          if obj[@time_key] == nil then
            raise "time_key not found in record: time-key=%s, reccord=%s" % [@time_key, obj]
          end
          if @time_format == nil then
            obj['time'] = obj[@time_key].to_i
          else
            obj['time'] = Time.strptime(obj[@time_key], @time_format).to_i
          end
        end
        return obj
      end
      def parse(line)
        raise "you must override parse method!!"
      end
    end

    class RegexLineParser < LineParser
      def initialize(opt)
        super(opt)
      end
      def get_keys(opt, converter)
        keys = opt[:keys].to_s.split(',')
        if keys.empty? && opt[:regex_pattern] != nil && !opt[:regex_pattern].names.empty? then
          keys = opt[:regex_pattern].names
        end
        return keys
      end
      def get_types(opt)
        return opt[:types].to_s.split(',')
      end
      def opt_parse(opt, converter=nil)
        super(opt, converter)
        # 正規表現のパターン
        @pattern = opt[:regex_pattern]
        # キーと型の情報を拾ってくる
        keys = get_keys(opt, converter)
        types = get_types(opt)
        if keys.empty? || types.empty? || keys.length != types.length then
          raise "keys or types is invalid."
        end
        # 型チェックしつつ、からむ情報を作る
        @columns = []
        types.each_with_index do | type, idx |
          column = {
            :key => keys[idx],
            :type => type,
          }
          unless [ 'string', 'bool', 'boolean', 'int', 'integer', 'long', 'number', 'float', 'double' ].include?(type) then
            # time型の場合はtime[FORMAT]の書式なのでFORMATを抜き出す
            if type.start_with?('time') then
              column[:type] = 'time'
              if /time\[(.+?)\]/ =~ type then
                column[:format] = $1
              else
                column[:format] = opt[:default_time_format]
              end
            else
              raise "type\"#{type}\" is invalid."
            end
          end
          @columns << column
        end
        @item_length = @columns.length
      end
      def split(line)
        md = @pattern.match(line.chomp)
        if md then
          return md.captures
        else
          # マッチしない場合はエラーレコードとしてCallbackする
          # TODO: 後で..
          raise "cannot match :pattern=#{@pattern} line=#{line}"
        end
      end
      def parse(line)
        items = split(line)
        if items.length == @item_length then
          record = {}
          items.each_with_index do | item, index |
            key  = @columns[index][:key]
            type = @columns[index][:type]
            case type
            when 'time'
              format = @columns[index][:format]
              value = Time.strptime(item, format).to_i
            when 'string'
              value = item.to_s
            when 'bool', 'boolean'
              # 多段switchってどうなのかな
              case item.downcase
              when 'false', 'no', '0'
                value = false
              when 'true', 'yes', '1'
                value = true
              when ''
                value = nil
              else
                value = !!item
              end
            when 'int', 'integer', 'long', 'number'
              value = item.to_i
            when 'float', 'double'
              value = item.to_f
            end
            record[key] = value
          end
          append_time(record)
          return record
        else
          # record-skipしたほうがいいかな
          raise "bad-format: parsed_line=%s" % [ items.inspect ]
        end
      end
    end

    class XSVLineParser < RegexLineParser
      def initialize(opt)
        super(opt)
        opt[:regex_pattern] = nil
      end
      def get_keys(opt, converter)
        keys = super(opt, converter)
        # 1行目をカラム情報として使う場合
        if opt[:use_header] then
          header = converter.input.gets.chomp
          # 先頭が#でコメントとみなす形式があるのでその対応
          header = header[1..-1] if header.start_with?('#')
          keys = split(header)
        end
        return keys
      end
      def split(line)
        raise "you must overwrite split method."
      end
    end

    class TSVLineParser < XSVLineParser
      def initialize(opt)
        super(opt)
      end
      def split(line)
        return line.chomp.split(/\t/)
      end
    end

    class CSVLineParser < XSVLineParser
      def initialize(opt)
        super(opt)
      end
      def split(line)
        return line.chomp.split(/\,/)
      end
    end

    class JSONLineParser < LineParser
      def initialize(opt)
        super(opt)
      end
      def opt_parse(opt, converter=nil)
        super(opt, converter)
      end
      def parse(line)
        json = JSON.parse(line)
        append_time(json)
        return json
      end
    end

    def initialize(opt)
      # パーサー定義
      @parsers = {
        :csv => CSVLineParser,
        :tsv => TSVLineParser,
        :json => JSONLineParser,
        :regex => RegexLineParser,
      }
      # 出力形式
      @output_formats = {
        :msgpack => lambda { |record| return MessagePack.pack(record) },
        :json => lambda { |record| return JSON.generate(record) },
      }
      @output_suffix_formats = {
        :msgpack => nil,
        :json => "\n",
      }
      # オプションの正当性チェック
      parse_options(opt)
    end

    # オプションの解析をして正しいかをチェックする
    # 必要なクラスのインスタンス化とかもする
    ## じゃないとパーサーのオプションチェックを起動できないため
    def parse_options(opt)
      
      # 入力
      @input = $stdin

      # パーサーの取得
      parser_class = @parsers[opt[:input_format].to_sym]
      raise "parser not found." if parser_class == nil 

      # パーサーの初期化とパーサー固有のオプションチェック
      @parser = parser_class.new(opt)
      @parser.opt_parse(opt, self)

      # 出力形式の決定
      @output_format = @output_formats[opt[:output_format].to_sym]
      @output_suffix_format = @output_suffix_formats[opt[:output_format].to_sym]
      raise "invalid output_format:" if @output_format == nil

      # 出力
      @output_writer = SplittableWriter.new(
        opt[:try_run] ? $stderr : $stdout,
        opt[:gzip],
        opt[:try_run] ? nil : opt[:output_dir],
        opt[:try_run] ? nil : opt[:output_filename],
        opt[:output_limit_size],
        )

      # 除外項目
      @exclude_keys = opt[:exclude_keys].to_s.split(',')

      @skip_rows = opt[:skip_rows]

    end
    
    def convert()

      # 各行を処理する 
      @input.each_line_with_index do | line, lnum |
        # データ行をSKIPする処理
        next if lnum < @skip_rows
        # 各行をごにょごにょ
        line.chomp!
        next if line.empty?

        record = @parser.parse(line)
        unless @exclude_keys.empty? then
          @exclude_keys.each do | del_key |
            record.delete(del_key)
          end
        end
        msg = @output_format.call(record)
        # どこに出力？
        @output_writer.write msg
        @output_writer.write @output_suffix_format if @output_suffix_format != nil
      end

      @output_writer.close()

    end

    attr_reader :input

  end
end

if __FILE__ == $0 then

  # オプションの解釈
  $OPTS = {
    :input_format => 'json',
    :output_format => 'msgpack',
    :keys => nil,
    :types => nil,
    :time_value => nil,
    :time_key => nil,
    :time_format => nil,
    :exclude_keys => nil,
    :use_header => false,
    :skip_rows => 0,
    :try_run => false,
    :gzip => false,
    :stdout => false,
    :output_dir => nil,
    :output_filename => nil,
    :output_limit_size => -1, #1024 * 1024 * 10,
    :detail_output => false,
    :regex_pattern => nil,
    :default_time_format => '%Y/%m/%d %T',
  }

  # TODO: try-run
  # TODO: -verbose
  # TODO: regexとぱたーん
  # TODO: Version定義
  # TODO: TSV出力をつけてHiveでも使えるようにする
  op = OptionParser.new
  op.on("--input-format={csv|tsv|json|regex}", '入力形式', '※csvもtsvも単純な書式しかサポートしない'){|v| $OPTS[:input_format] = v}
  op.on("--output-format={json|msgpack}", '出力形式'){|v| $OPTS[:output_format] = v}
  op.on("--keys=KEY[,KEY]*", '各項目の名前'){|v| $OPTS[:keys] = v}
  op.on('--types=TYPES', 
        'TYPES=[TYPE]+', 
        'TYPE=string|int|integer|long|bool|boolean|float|double|time[TIME_FORMAT]', 
        'TIME_FORMAT=Time.parseの書式'){|v| 
          $OPTS[:types] = v
      }
  op.on('--tv=UNIXTIME|STRIING', '--time-value=UNIXTIME|STRING', 'time属性の値.UNIXTIMEを指定', '別途--time-formatを使えば任意の書式を指定可能'){|v| $OPTS[:time_value] = v}
  op.on('--tk=KEY', '--time-key=KEY', 'time属性として使うキー'){|v| $OPTS[:time_key] = v}
  op.on('--time-format=FORMAT', 'time-valueの書式。指定しないとUNIXTIMEとして扱う'){|v| $OPTS[:time_format] = v}
  op.on('--exclude-keys=KEY[,KEY]*', '除外する項目'){|v| $OPTS[:exclude_keys] = v}
  op.on('--use-header', 'CSVかTSVの場合にヘッダ行を処理して属性名として使用する'){|v| $OPTS[:use_header] = true}
  op.on('--skip-rows=NUM', '最初の行を指定した数だけ飛ばす'){|v| $OPTS[:skip_rows] = v.to_i}
  op.on('--pattern=REGEX-PATTERN', 'regex形式のパターン指定。', '入力形式がregexの時に有効'){|v| $OPTS[:regex_pattern] = Regexp.new(v)}
  op.on('--default-time-format=TIME_FORMAT', 'time型の書式を省略した場合の書式', 'デフォは"%Y/%m/%d %T"'){|v| $OPTS[:default_time_format] = v}
  op.on('-n', '--try-run', '--dry-run', '1行だけ処理をして結果はSTDERRへ出力'){|v| $OPTS[:try_run] = true}
  op.on('-z', '--gzip', '出力をGZIP処理する'){|v| $OPTS[:gzip] = true}
  op.on('-c', '--stdout', '出力をSTDOUTに出力する'){|v| $OPTS[:stdout] = true}
  op.on('-d', '--output-dir=DIR', 'ファイルに出力する場合の出力先ディレクトリ', '省略時はカレントディレクトリ'){|v| $OPTS[:output_dir] = v}
  op.on('-o', '--output-filename=FILE', 'ファイルに出力する場合のファイル名'){|v| $OPTS[:output_filename] = v}
  op.on('-l', '--limit=NUM', '分割する場合のサイズ.単位はMbyte', '省略時は分割しない'){|v| $OPTS[:output_limit_size] = v.to_i * 1024 * 1024}
  op.on('-v', '--verbose', '処理の詳細表示'){|v| $OPTS[:detail_output] = true}
  op.parse!(ARGV)

  #pp $OPTS
  conv = TreasureData::Converter.new($OPTS)
  conv.convert() 

end


