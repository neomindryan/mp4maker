#!/usr/bin/env ruby

# Convert an MKV with softsubs to an M4V file with softsubs.
# Dependencie:
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
      nice -n 19 /usr/local/bin/HandBrakeCLI -i "#{input}" -o "#{output}" --crop 0:0:0:0 -X 720 -Y 480 -e x264 -S #{filesize} -2 -T -P \
        -x 'vbv_maxrate=4500:vbv_bufsize=3000:threads=auto:ref=6:subq=6:me=umh:no-fast-pskip=1:level=3.0:mixed-refs=1:merange=24:direct=auto:analyse=all:cabac=0'
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

require 'rubygems'
require 'logger'

log = Logger.new(STDOUT)
log.datetime_format = "" # Keep it simple
log.level = Logger::DEBUG
if ARGV.delete("-s")
  log.level = Logger::ERROR
end

mkv_file = ARGV[0]
m4v_file = ARGV[1]
unless mkv_file 
  log.error "Syntax:\n\tmkvert <mkv_file[.mkv]> [m4v_file[.m4v]]"
  exit
end
mkv_base_name = mkv_file.gsub(/\.mkv$/, '')
mkv_file += ".mkv" if mkv_base_name == mkv_file
if m4v_file
  m4v_base_name = m4v_file.gsub(/\.m4v$/, '')
  m4v_file += ".m4v" if m4v_base_name == m4v_file
end

##### Transcode the video if a transcoded file wasn't provided
if m4v_file && !File.exists?(m4v_file)
  log.error("Unable to find .M4V file: #{m4v_file}")
  exit
elsif m4v_file.nil? # Transcode the m4v file if one wasn't specified.
  m4v_base_name = mkv_base_name
  m4v_file = m4v_base_name + ".m4v"
  log.info "Transcoding mkv file to m4v"
  quick_encode(mkv_file)
end

##### Extract the subtitles and convert them to SRT format if necessary
log.info "Searching for SRT track..."
desired_track = `mkvmerge --identify "#{mkv_file}" | grep 'S_TEXT/UTF8'`
if desired_track.nil? || /Track ID (\d+)/.match(desired_track).nil?
  log.info "No SRT track found, searching for ASS"
  desired_track = `mkvmerge --identify "#{mkv_file}" | grep 'S_TEXT/ASS'`
  if desired_track.nil? || /Track ID (\d+)/.match(desired_track).nil?
    log.error "No subtitle track found in #{mkv_file}"
    exit
  end
  subtitle_type = "ASS"
else
  subtitle_type = "SRT"
end
desired_track = /Track ID (\d+)/.match(desired_track)[1].to_i
desired_track = desired_track.to_i

srt_file = "#{mkv_base_name}.srt"
if subtitle_type == "ASS"
  ass_file = "#{mkv_base_name}.ass"
  log.info "Exporting from ASS track #{desired_track} ..."
  extract_command = "mkvextract tracks \"#{mkv_file}\" #{desired_track}:\"#{ass_file}\""
  `#{extract_command}`
  if !File.exists?(ass_file)
    log.error "Unable to export file using command #{extract_command}"
    exit
  end
  log.info "Converting subtitles from ASS to SRT..."
  `ass2srt.pl "#{ass_file}"`
  if !File.exists?(srt_file)
    log.error "Unable to convert ASS file to SRT"
    exit
  end
elsif subtitle_type == "SRT"
  log.info "Exporting SRT from track #{desired_track} ..."
  extract_command = "mkvextract tracks \"#{mkv_file}\" #{desired_track}:\"#{srt_file}\""
  `#{extract_command}`
  if !File.exists?(srt_file)
    log.error "Unable to export file using command #{extract_command}"
    exit
  end
end # if subtitle_type == "SRT"

##### Mux the M4V and SRT files
log.info "Muxing subtitles into .M4V file '#{m4v_file}' ..."
`SublerCLI -i "#{m4v_file}" -s "#{srt_file}"`

##### Cleanup
if subtitle_type == "ASS"
  log.info "Cleaning up ASS file..."
  File.delete(ass_file)
end
log.info "Cleaning up SRT file..."
File.delete(srt_file)
