#!/usr/bin/env ruby

# Convert an MKV with softsubs to an M4V file with softsubs.
# OR just convert an AVI to an M4V
# Dependencies:
#   ass2srt.pl (if you have MKV files with no SRT track)
#     http://blog.t-times.net/ada/space/start/2006-07-31/2/ass2srt.pl
#   subler (for muxing subtitles into mp4)
#     http://code.google.com/p/subler/
#   mkvtoolnix (for exploring mkv files & extracting tracks)
#     brew install mkvtoolnix # has a lot of dependencies
#   HandBrakeCLI (for transcoding audio & video tracks)
#     http://handbrake.fr/?article=download

def quick_encode(input, options={})
  log = options[:log]
  force_transcode = options.delete(:force_transcode)

  if options[:source_type] != 'mkv' || force_transcode
    log.info("Transcode forced") if force_transcode
    log.info("Source file was of type #{options[:source_type]}; transcoding.") if options[:source_type] != 'mkv'
    quick_transcode(input, options)
    return
  end
  mkvfile = MkvFile.new(input)
  if mkvfile.can_be_repackaged_as_mp4?
    log.info("File seems like it can be repackaged; using quick_rewrap")
    quick_rewrap(input, options)
  else
    log.info("File does not seem like it can be repackaged; using quick_transcode")
    quick_transcode(input, options)
  end
end

# Use SublerCLI to repackage the file as an mp4
def quick_rewrap(input, options={})
  command = "SublerCLI -i '#{input}' -O -l English -o '#{input.gsub(/\.[^.]+$/i, '')}.m4v'"
  exec command
end

# this uses the original file size as the target size, which is a cheap way to get similar quality
#   quickEncode was originally a bash alias to HandBrakeCLI with default conversion settings for A/V by Matt Stocum
#  @param quality Matt recommends 20 for HD, 19 for DVD content (19 is better)
def quick_transcode(input, options={})
  quality = options[:quality] || 19
  log = options[:log]
  output = input.gsub(/\.[^.]*$/, '.m4v')

  # TODO Next time this is needed, make the options below detect its use.
  pcm_input = nil
  # extract the audio to PCM with ffmpeg first because sometimes HandBrakeCLI has problems
  # pcm_input = "#{input}-temp.avi"
  # command = <<-EOS
  #   nice -n 19 ffmpeg -i "#{input}" -acodec adpcm_ms -vcodec copy "#{pcm_input}"
  # EOS
  # input = pcm_input # we no longer care about the original.
  # command = command.strip
  # # log.info "Extracting audio to PCM with ffmpeg..."
  # puts "Prepping with ffmpeg using: #{command}"
  # system(command)

  # x264opts will be passed to the '-x' argument of HandBrakeCLI
  # I took these from the advanced tab of the HandBrake 0.9.5 x86_64 (2011010300) GUI for the AppleTV preset
  x264opts = {
    :'cabac' => '0',
    :'ref' => '2',
    :'me' => 'umh',
    :'b-pyramid' => 'none',
    :'b-adapt' => '2',
    :'weightb' => '0',
    :'trellis' => '0',
    :'weightp' => '0',
    :'vbv-maxrate' => '9500',
    :'vbv-bufsize' => '9500' }

  options = {
    :'-i' => %{"#{input}"},
    :'-o' => %{"#{output}"},
    :'--crop' => '0:0:0:0',
    :'-X' => '1280',
    :'-Y' => '720',
    :'-e' => 'x264',
    :'-q' => quality,
    :'--loose-anamorphic' => nil,
    :'--markers' => nil, # chapter markers
    :'-x' => x264opts.map{|k,v| "#{k}=#{v}"}.join(':') }

  # Now transcode the video and re-mux / transcode in the audio extracted by ffmpeg
  command = "nice -n 19 HandBrakeCLI #{options.map{|k,v| "#{k} #{v}"}.join(" ")}"
  command = command.gsub(/ +/, ' ').strip
  # puts "doing it!: #{command}"
  system(command) # backticks wont work here.

  # if we're using the intermediate pcm-audio step, clean up after ourselves.
  if pcm_input
    # log.info "Cleaning up ffmpeg intermediate step..."
    File.delete(pcm_input)
  end

  if options[:source_type] == "mkv"
    mkv_options = []
    mkvoptions[:log] = log if log
    mkv_file = MkvFile.new(source_file, mkv_options)
    ##### TODO extract any chapter info and import it

    if mkv_file.subtitles?
      srt_file = mkv_file.export_subtitles_as_srt

      ##### Mux the M4V and SRT files
      log.info "Muxing subtitles into .M4V file '#{m4v_file}' ..." if log
      `SublerCLI -i "#{m4v_file}" -s "#{srt_file}"`

      mkv_file.cleanup_subtitle_files
    end
  end
end # quick_encode

# TODO add support for multiple subtitle tracks
class MkvFile
  attr_reader :filename, :base_name, :subtitle_type, :srt_file, :ass_file, :log
  def initialize(filename, options = {})
    @filename = filename
    match = /(.*)\.(mkv|avi)/.match(filename)
    raise "Invalid filename #{filename}" unless @base_name = match[1]
    raise "source file is not an MKV file" unless match[2].downcase == 'mkv'
    @log = options[:log]
  end

  # this will likely need to get smarter.
  def can_be_repackaged_as_mp4?
    # If there's an mp4 track, assume this can be rewrapped as an mp4
    !!(find_id_of_track_type('V_MPEG4/ISO/AVC') && find_id_of_track_type('A_AAC'))
  end

  def subtitles?
    !!subtitle_type
  end

  def subtitle_type
    @subtitle_type ||= if srt_track_id
      'srt'
    elsif ass_track_id
      'ass'
    else
      nil
    end
  end

  def srt_track_id
    @srt_id ||= find_id_of_track_type('S_TEXT/UTF8')
  end
  def srt_file
    # This file is used wether there's an ASS file or a SRT file.
    subtitles? ? "#{base_name}.srt" : nil
  end

  def ass_track_id
    @ass_id ||= find_id_of_track_type('S_TEXT/ASS')
  end
  def ass_file
    ass_track_id ? "#{base_name}.ass" : nil
  end

  def find_id_of_track_type(desired_type)
    desired_track = `mkvmerge --identify "#{@filename}" | grep '#{desired_type}'`
    track_id = nil
    match = /Track ID (\d+)/.match(desired_track)
    track_id = match[1].to_i if match
  end

  def export_ass
    return nil unless subtitle_type == 'ass'
    log.info "Exporting from ASS track #{ass_track_id} ..." if log
    extract_command = "mkvextract tracks \"#{@filename}\" #{ass_track_id}:\"#{ass_file}\""
    `#{extract_command}`

    raise "Unable to export file using command #{extract_command}" unless File.exists?(ass_file)
    ass_file
  end

  def convert_ass_to_srt
    if !File.exists?(ass_file)
      raise "Unable to find ASS file: #{ass_file}"
    end
    log.info "Converting subtitles from ASS to SRT..." if log
    `ass2srt.pl "#{ass_file}"`

    raise "Unable to convert ASS file to SRT" unless File.exists?(srt_file)
    srt_file
  end

  def export_srt
    return nil unless subtitle_type == 'srt'
    log.info "Exporting SRT from track #{srt_track_id} ..." if log
    extract_command = "mkvextract tracks \"#{@filename}\" #{srt_track_id}:\"#{srt_file}\""
    `#{extract_command}`

    raise "Unable to export file using command #{extract_command}" unless File.exists?(srt_file)
    srt_file
  end

  def export_subtitles_as_srt
    if export_ass
      convert_ass_to_srt
    else
      export_srt
    end
  end

  def cleanup_subtitle_files
    if File.exists?(ass_file)
      log.info "Cleaning up ASS file..." if log
      File.delete(ass_file)
    end
    if File.exists?(srt_file)
      log.info "Cleaning up SRT file..." if log
      File.delete(srt_file)
    end
  end
end

require 'rubygems'
require 'logger'

log = Logger.new(STDOUT)
log.datetime_format = "" # Keep it simple
log.level = Logger::DEBUG
if ARGV.delete("-s")
  log.level = Logger::ERROR
end

if ARGV[0] == '-f'
  force_transcode = true
  source_file = ARGV[1]
  m4v_file = ARGV[2]
else
  force_transcode = false
  source_file = ARGV[0]
  m4v_file = ARGV[1]
end
unless source_file
  log.error "Syntax:\n\tmkvert [-f] <source_file[.mkv|avi]> [m4v_file[.m4v]]\n\tOR\n\tmkvert <directory containing avi and/or mkv files>"
  exit
end
match = /(.*)\.(mkv|avi)/.match(source_file)
raise "#{source_file} is not an AVI or MKV file" unless match
source_base_name = match[1]
source_type = match[2].downcase
if m4v_file
  m4v_base_name = m4v_file.gsub(/\.m4v$/, '')
  m4v_file += ".m4v" if m4v_base_name == m4v_file
end

##### Transcode the video if a transcoded file wasn't provided
if m4v_file && !File.exists?(m4v_file)
  log.error("Unable to find .M4V file: #{m4v_file}")
  exit
elsif m4v_file.nil? # Transcode the m4v file if one wasn't specified.
  m4v_base_name = source_base_name
  m4v_file = m4v_base_name + ".m4v"
  log.info "Transcoding #{source_type} file to m4v"
  quick_encode(source_file, :log => log, :source_type => source_type, :force_transcode => force_transcode)
end
