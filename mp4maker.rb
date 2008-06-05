#!/usr/bin/ruby

require 'optparse'
require 'ostruct'
require 'open3'

class MediaFormatException < StandardError
end

def safe_execute
  yield
rescue
  print "ERROR\n"
  exit 1
end

def execute_ffmpeg(command)
  progress = nil
  IO.popen(command) do |pipe|
    pipe.each("\r") do |line|
      if line =~ /Duration: (\d{2}):(\d{2}):(\d{2}).(\d{1})/
        duration = (($1.to_i * 60 + $2.to_i) * 60 + $3.to_i) * 10 + $4.to_i
      end
      if line =~ /time=(\d+).(\d+)/
        if not duration.nil? and duration != 0
          p = ($1.to_i * 10 + $2.to_i) * 100 / duration
        else
          p = 0
        end
        p = 100 if p > 100
        if progress != p
          progress = p
          print "PROGRESS: #{progress}\n"
          $defout.flush
        end
      end
    end
  end
  raise MediaFormatException if $?.exitstatus != 0
end

def execute_mencoder(command)
  progress = nil
  Open3.popen3(command) do |x, pipe, y|
    pipe.each("\r") do |line|
      if line =~ /(\d+%)\)\s+([0-9.]+fps).*Trem:\s+(\d+min)/
          print "\rPercent complete: " + $1 + ".  Time remaining: " + $3 + ". Speed: " + $2 + "    "
          $defout.flush
      end
    end
  end
  print "\n"
  raise MediaFormatException if $?.exitstatus != 0
end

class OptionParser
	def self.parse(args)
		options = OpenStruct.new
		options.twopass = false
		options.profile = "ipod"
		
		opts = OptionParser.new do |opts|
			opts.banner	= "Usage: mp4maker [-2] -[p encoder profile] {input file(s)}"
			
			opts.separator ""
			opts.separator "Specific options:"
	
			opts.on("-2", "--two-pass", "Enable two-pass encoding") do |two|
				options.twopass = two
			end

			opts.on("-p", "--profile [encoder profile]", "Selected encoder profile") do |prof|
				options.profile = prof
			end
		end.parse!(args)
		options
	end
end

options = OptionParser.parse(ARGV)

puts "Using " + options.profile + " profile."
if options.twopass
	puts "Two-pass encoding enabled."
end

# audio (aac): -oac faac -faacopts mpeg=4:object=2:br=128:raw=yes -af lavcresample=44100 -of lavf -lavfopts format=mp4
# video (ipod): -ovc x264 -x264encopts global_header:vbv_maxrate=1500:vbv_bufsize=2000:keyint=500:threads=auto:subq=6:me=umh:cabac=0:psnr=yes:bitrate=1200:level=3 -vf harddup -vf scale=w=640:h=-1:noup=1
# video (appletv-hd): -ovc x264 -x264encopts global_header:vbv_maxrate=5000:vbv_bufsize=2000:bitrate=2500:keyint=500:threads=auto:bframes=0:ref=1:subq=6:me=umh:no-fast-pskip=1:trellis=2:cabac=0:level=3.1 -vf harddup -vf scale=w=1280:h=-1:noup=1

# mencoder  

video = Hash.new()
video['ipod'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=1500:vbv_bufsize=2000:keyint=500:threads=auto:subq=6:me=umh:cabac=0:psnr=yes:bitrate=1200:level=3 -vf harddup -vf scale=w=640:h=-1:noup=1'
video['ipod-pass1'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=1500:vbv_bufsize=2000:keyint=500:threads=auto:subq=1:cabac=0:psnr=yes:bitrate=1000:level=3:pass=1 -vf harddup -vf scale=w=640:h=-1:noup=1'
video['ipod-pass2'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=1500:vbv_bufsize=2000:keyint=500:threads=auto:subq=6:me=umh:cabac=0:psnr=yes:bitrate=1000:level=3:pass=2 -vf harddup -vf scale=w=640:h=-1:noup=1'
video['appletv-hd'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=5000:vbv_bufsize=2000:bitrate=2500:keyint=500:threads=auto:bframes=0:ref=1:subq=6:me=umh:no-fast-pskip=1:trellis=2:cabac=0:level=3.1 -vf harddup -vf scale=w=1280:h=-1:noup=1'
video['appletv-hd-pass1'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=5000:vbv_bufsize=2000:bitrate=2500:keyint=500:threads=auto:bframes=0:frameref=1:subq=1:no-fast-pskip=1:trellis=2:cabac=0:level=3.1:pass=1 -vf harddup -vf scale=w=1280:h=-1:noup=1'
video['appletv-hd-pass2'] = '-ovc x264 -x264encopts global_header:vbv_maxrate=5000:vbv_bufsize=2000:bitrate=2500:keyint=500:threads=auto:bframes=0:frameref=1:subq=5:me=umh:partitions=all:no-fast-pskip=1:trellis=2:cabac=0:level=3.1:pass=2 -vf harddup -vf scale=w=1280:h=-1:noup=1'

audio = Hash.new()
audio['aac'] = '-oac faac -faacopts mpeg=4:object=2:br=128:raw=yes -af lavcresample=44100 -of lavf -lavfopts format=mp4'

ARGV.each do |inputFile|
	outputFile = inputFile.gsub(/\.[^.]*$/, '.m4v')
	if options.twopass
		commandline='nice mencoder "' + inputFile + '" -nosound ' + video[options.profile + '-pass1'] + ' -o /dev/null && nice mencoder "' + inputFile + '" ' + audio['aac'] + ' ' + video[options.profile] + ' -o "' + outputFile + '"'
	else
		commandline='nice mencoder "' + inputFile + '" ' + audio['aac'] + ' ' + video[options.profile] + ' -o "' + outputFile + '"'
	end
	
	puts "Encoding " + outputFile
	safe_execute do
#		puts commandline
		execute_mencoder(commandline)
	end
end