#!/usr/bin/env ruby

# Convert an MKV with softsubs to an M4V file with softsubs.
# OR just convert an AVI to an M4V
# Dependencies:
#   ass2srt.pl (if you have MKV files with no SRT track)
#     http://blog.t-times.net/ada/space/start/2006-07-31/2/ass2srt.pl
#   subler (for muxing subtitles into mp4)
#     http://code.google.com/p/subler/
#   mkvtoolnix (for exploring mkv files & extracting tracks)
#     sudo port install mkvtoolnix # has a lot of dependencies
#   HandBrakeCLI (for transcoding audio & video tracks)
#     http://handbrake.fr/?article=download

# this uses the original file size as the target size, which is a cheap way to get similar quality
#   quickEncode was originally a bash alias to HandBrakeCLI with default conversion settings for A/V by Matt Stocum
def quick_encode(*args)
  args.each do |input|
    output = input.gsub(/\.[^.]*$/, '.m4v')
    filesize = `BLOCKSIZE=1048576 du -s "#{input}"`
    filesize = /(\d+).*/.match(filesize)[1]
    raise "Couldn't determine size of #{input}" unless /\d+/.match(filesize)

    pcm_input = nil
    # extract the audio to PCM with ffmpeg first because sometimes HandBrakeCLI has problems
#     pcm_input = "#{input}-temp.avi"
#     command = <<-EOS
#       nice -n 19 ffmpeg -i "#{input}" -acodec adpcm_ms -vcodec copy "#{pcm_input}"
#     EOS
#     input = pcm_input # we no longer care about the original.
#     command = command.strip
#     # log.info "Extracting audio to PCM with ffmpeg..."
#     puts "Prepping with ffmpeg using: #{command}"
#     system(command)

    # Now transcode the video and re-mux / transcode in the audio extracted by ffmpeg
    command = <<-EOS
      nice -n 19 /usr/local/bin/HandBrakeCLI -i "#{input}" -o "#{output}" --crop 0:0:0:0 -X 1280 -Y 720 -e x264 -S #{filesize} -2 -T --loose-anamorphic \
        -x 'vbv_maxrate=4500:vbv_bufsize=3000:threads=auto:ref=6:subq=6:me=umh:no-fast-pskip=1:level=3.0:mixed-refs=1:merange=24:direct=auto:analyse=all:cabac=0:bframes=0'
    EOS
    command = command.strip
    # puts "doing it!: #{command}"
    system(command) # backticks wont work here.

    # if we're using the intermediate pcm-audio step, clean up after ourselves.
    if pcm_input
      # log.info "Cleaning up ffmpeg intermediate step..."
      File.delete(pcm_input)
    end
  end # args.each
end # quick_encode

class MkvFile
  attr_reader :filename, :base_name, :subtitle_type, :srt_file, :ass_file, :log
  def initialize(filename, options = {})
    @filename = filename
    match = /(.*)\.(mkv|avi)/.match(filename)
    raise "Invalid filename #{filename}" unless @base_name = match[1]
    raise "source file is not an MKV file" unless match[2].downcase == 'mkv'
    @log = options[:log]
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
    srt_track_id ? "#{base_name}.srt" : nil
  end

  def ass_track_id
    @ass_id ||= find_id_of_track_type('S_TEXT/ASS')
  end
  def ass_file
    ass_track_id ? "#{base_name}.ass" : nil
  end

  def find_id_of_track_type(desired_type)
    desired_track = `mkvmerge --identify "#{source_file}" | grep '#{desired_type}'`
    track_id = nil
    match = /Track ID (\d+)/.match(desired_track)
    track_id = match[1].to_i if match
  end

  def export_ass
    return nil unless subtitle_type == 'ass'
    log.info "Exporting from ASS track #{ass_track_id} ..." if log
    extract_command = "mkvextract tracks \"#{filename}\" #{ass_track_id}:\"#{ass_file}\""
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
    extract_command = "mkvextract tracks \"#{source_file}\" #{srt_track_id}:\"#{srt_file}\""
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

source_file = ARGV[0]
m4v_file = ARGV[1]
unless source_file
  log.error "Syntax:\n\tmkvert <source_file[.mkv|avi]> [m4v_file[.m4v]]"
  exit
end
match = /(.*)\.(mkv|avi)/.match(source_file)
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
  quick_encode(source_file)
end

if source_type == "mkv"
  mkv_file = MkvFile.new(source_file, :log => log)
  ##### TODO extract any chapter info and import it

  if mkv_file.subtitles?
    srt_file = mkv_file.export_subtitles_as_srt

    ##### Mux the M4V and SRT files
    log.info "Muxing subtitles into .M4V file '#{m4v_file}' ..."
    `SublerCLI -i "#{m4v_file}" -s "#{srt_file}"`

    mkv_file.cleanup_subtitle_files
  end
end
