# Copyright (c) 2009, University of Washington
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of the University of Washington nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# wraps our probing tools in an object

require 'drb'
require 'drb/acl'
require 'net/http' 
require 'socket'
require "vp_config.rb"

class Prober
	# allows controller to call back to issue measurements, etc

	include DRbUndumped
	include ProberConfig

	PROBER_VERSION = "$Id: prober.rb,v 1.13 2011/07/13 22:29:54 ethan Exp $".split(" ").at(2).to_f

	def Prober::uri2host(uri)
		uri.chomp("\n").split("/").at(-1).split(":").at(0)
	end

	# build an acl from a uri allowing only connections from localhost and the
	# host of the uri
	def Prober::build_acl(uri)
		ACL.new(["deny","all","allow","localhost","allow","127.0.0.1","allow",Prober::uri2host(uri)])
	end

	# fetch the default controller uri
	# throws an exception if the uri is obviously not proper
	def Prober::get_default_controller_uri
		controller_uri = Net::HTTP.get_response(URI.parse(Prober::CONTROLLER_INFO)).body.chomp("\n")
		if not controller_uri[0..7]=="druby://"
			raise DRb::DRbBadURI, "Bad controller uri: #{controller_uri}", caller
		end
		controller_uri
	end

	# takes the directory to look for probing tools in
	# if nil, then looks in Prober::DEFAULT_PROBEROUTE_DIR
	# optionally, takes a path to store temp output in
	# if DRb service is running, @drb should be set
	# so @drb.nil? can be used to check if it is running
	def initialize(proberoute_dir,output_dir=Prober::DEFAULT_TMP_OUTPUT_DIR)
		@drb=nil
		@counter_mutex=Mutex.new
		@count=0
		@device=self.set_device
		if proberoute_dir.nil?
			@proberoute_dir=Prober::DEFAULT_PROBEROUTE_DIR
		else
			@proberoute_dir=proberoute_dir
		end
		@output_dir=output_dir
        killall_receive
	end
	attr_reader :device, :drb
	attr_writer :device

	# whether an upgrade to this version from an earlier one requires a
	# restart
	# should be set to false, unless a particular version needs it
	# doing it as a method in case we ever need more logic in it
	def restart_prober?
		false
	end

	def uri
		return nil if @drb.nil?
		return @drb.uri
	end

	def set_device
		@device="eth0"
		current_packets=0
		`cat /proc/net/dev |grep eth`.each_line{|interface_stats|
			device=interface_stats.chomp("\n").strip.split(":").at(0)
			next if not device[0..2]=="eth"
			packets=interface_stats.chomp("\n").strip.split(":").at(1).strip.split(" ").at(1).to_i
			if packets>current_packets
				@device, current_packets = device, packets
			end
		}
		@device
	end

	# acl may be nil
	# front_prober is whether to front the prober on the DRb (returning it via
	# the URI), or just to start up the service to allow connections out
	# if successful, will set @drb
	def start_service(acl,front_prober,port=Prober::DEFAULT_PORT)
		front = ( front_prober ? self : nil )
		begin
			hostname=Socket::gethostname
			if hostname.include?("measurement-lab.org")
				hostname=UDPSocket.open {|s| s.connect(Prober::TEST_IP, 1); s.addr.last}
			end
			uri="druby://#{hostname}:#{port}"
			@drb=(DRb.start_service uri, front, acl)
		rescue 
			begin
				$stderr.puts "Did not work on #{uri} port, retrying nil port"
				@drb=(DRb.start_service nil, front, acl)
			rescue 
				uri="druby://#{hostname}:#{50000+rand(15000)}"
				$stderr.puts "Did not work on nil port, retrying #{uri}"
				@drb=(DRb.start_service uri, front, acl)
			end
		end
		self.log("Started on #{@drb.uri}")
	end

	def stop_service
		self.log("Stopping DRb service")
		begin
			if not @drb.nil?
				@drb.stop_service
				@drb=nil
			end
		rescue
			self.log($!.to_s)
		end
	end

	def shutdown(code=0)
		self.log "Exiting: Received shutdown message #{code}"
		Thread.new{
			sleep 1
			Kernel.exit(code)
		}
	end

	def log(msg,except=nil)
		$stderr.puts `date +%Y/%m/%d.%H%M.%S`.chomp("\n") + " " + msg + (except.nil? ? "" : " #{except.class} #{except.to_s}")
	end

	def hostname
		if self.uri.nil?
			begin
				Socket::gethostname
			rescue
				UDPSocket.open {|s| s.connect('128.208.2.159', 1); s.addr.last }
			end
		else
			Prober::uri2host(self.uri)
		end
	end

	def port
		(self.uri.nil?) ? nil : self.uri.chomp("\n").split("/").at(-1).split(":").at(1)
	end

	def remove_files(*files)
		files.each{|f|
			begin
				if File.exist?(f)
					File.delete(f)
				end
			rescue 
				self.log "Exception: Can't delete file #{$!.to_s}"
			end
		}
	end

	# create an appropriately named target file
	# file_writer is a block that take the file and properly "fills" it
	# return the name of the file
	def create_target_file( &file_writer )
		uid=0
		@counter_mutex.synchronize do
			uid=@count
			@count += 1
		end
		fn="#{@output_dir}/targs_#{self.port}_#{uid}.txt"
		File.open( fn, File::CREAT|File::TRUNC|File::WRONLY|File::APPEND) {|targf|
			file_writer.call(targf)
		}
		return fn
	end

	def traceroute( targs )
		self.log "Sending #{targs.length} traceroutes"
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		`sudo #{@proberoute_dir}/randstprober #{Prober::PROBING_THREADS} #{fn} #{@device} 1 #{fn}.trace.out #{fn}.count.out`
		`sudo chown \`id -u\` #{fn}.trace.out #{fn}.count.out`
		f=nil
		begin
			f=File.new("#{fn}.trace.out")
			probes=f.read
			self.remove_files("#{fn}.trace.out", fn, "#{fn}.count.out")
			return probes
		ensure
			f.close unless f.nil?
		end
	end

    def paristrace(target)
        self.log "Running Paris traceroute towards #{target}"
        fn = "#{@output_dir}/paristrace_output_#{self.port}_#{target}"
        self.log "sudo #{@proberoute_dir}/ptrun/ptrun.py -d #{target} -o #{fn}.bin -s #{fn}.txt"
        `cd #{@proberoute_dir}/ptrun && sudo ./ptrun.py -d #{target} -o #{fn}.bin -s #{fn}.txt`
        `sudo chown $(id -u) #{fn}.bin #{fn}.txt`
        hops = IO.read("#{fn}.txt")
        remove_files("#{fn}.txt", "#{fn}.bin")
        return hops
    end

	def ping( targs )
		self.log "Sending #{targs.length} pings"
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		probes=`sudo #{@proberoute_dir}/aliasprobe #{Prober::PROBING_THREADS} #{fn} #{@device}`
		self.remove_files(fn)
		return probes
	end

	def rr( targs )
		self.log "Sending #{targs.length} record-routes"
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		`sudo #{@proberoute_dir}/rrping #{Prober::PROBING_THREADS} #{fn} #{@device} #{fn}.rrping.out` 
		`sudo chown \`id -u\` #{fn}.rrping.out #{fn}.rrping.out.ttl`
		f=nil
		begin
			f=File.new("#{fn}.rrping.out")
			probes=f.read
			self.remove_files(fn,"#{fn}.rrping.out","#{fn}.rrping.out.ttl")
			return probes
		ensure
			f.close unless f.nil?
		end
	end

	def ts( probes )
		self.log "Sending #{probes.length} timestamps"
		fn=create_target_file{|targ_file| probes.each{|probe| targ_file.puts probe.join(" ")}}
		results=`sudo #{@proberoute_dir}/tsprespec-ping	 #{Prober::PROBING_THREADS} #{fn} #{@device}`
		self.remove_files(fn)
		return results
	end

	# probes is hash[receiver] -> [dst1, dst2,...]
	# for some reason, the m-lab nodes don't like it if i iterate through the
	# hash as a hash... they try to make an RPC call to themselves, which
	# fails bc it is using the hostname, not the IP
	# so instead, treat the keys as an array
	def spoof_rr(probes, id=45678)
		fn=create_target_file{|targf|
			probes.keys.each{|rec|
				dsts=probes[rec]
				self.log "Spoofing #{rec} for #{dsts.length} record-routes"
				dsts.each{|d|
					targf.puts d + " " + rec
				}
			}
		}
		`sudo #{@proberoute_dir}/rrspoof #{Prober::PROBING_THREADS} #{fn} #{@device} #{id}`
		self.remove_files(fn)
	end

	# probes is hash[receiver] -> [[dst1,ts1,ts2,...], [dst2,ts3,ts4,...],...]
	# for some reason, the m-lab nodes don't like it if i iterate through the
	# hash as a hash... they try to make an RPC call to themselves, which
	# fails bc it is using the hostname, not the IP
	# so instead, treat the keys as an array
	def spoof_ts(probes, id=45678)
		fn=create_target_file{|targf|
			probes.keys.each{|rec|
				tss=probes[rec]
				self.log "Spoofing #{rec} for #{tss.length} timestamps"
				tss.each{|ts|
					targf.puts rec + " " + ts.join(" ")
				}
			}
		}
		`sudo #{@proberoute_dir}/tsprespec-spoof #{Prober::PROBING_THREADS} #{fn} #{@device} #{id}`
		self.remove_files(fn)
	end

	def receive_spoofed_probes(id, type=:rrspoof)
		uid=0
		`sudo pkill -9  -f "(tsprespec|rrspoof)-recv [^\s]+ [^\s]+ #{id}"`
		@counter_mutex.synchronize do
			uid=@count
			@count += 1
		end
		fn="#{@output_dir}/spoof_#{self.port}_#{uid}_#{type}ping.out"
		# CUNHA parallelization: commented the following line
		# `sudo killall -9 -e #{type}-recv 1> /dev/null 2>&1`
		self.log "Receiving spoofed #{type} #{fn}"
		Thread.new{`sudo #{@proberoute_dir}/#{type}-recv #{@device} #{fn} #{id}`}
		return fn
	end

	def receive_spoofed_rr(id=45678)
		receive_spoofed_probes(id, :rrspoof)
	end

	def receive_spoofed_ts(id=45678)
		receive_spoofed_probes(id, :tsprespec)
	end

    # kill all receive commands, to get rid of zombies
    def killall_receive
		`sudo killall -9 -e tsprespec-recv 1> /dev/null 2>&1`
		`sudo killall -9 -e rrspoof-recv 1> /dev/null 2>&1`
    end

	# kill receivers and retrieve results
	# does killall at the moment - makes it not safe to make multiple receive
	# calls at once
	def kill_and_retrieve(fid, id=45678)
		# CUNHA paralellization: changed kill commands
		# `sudo killall -9 -e tsprespec-recv 1> /dev/null 2>&1`
		# `sudo killall -9 -e rrspoof-recv 1> /dev/null 2>&1`
		`sudo pkill -9  -f "(tsprespec|rrspoof)-recv [^\s]+ [^\s]+ #{id}"`
		f=nil
		begin
			self.log "Retrieving #{fid}"
			f=File.new(fid)
			probes=f.read
			sources=IO.readlines(fid + ".src").collect{|x| x.chomp("\n")}
			`sudo chown \`id -u\` #{fid} #{fid}.src`
			to_remove=[fid,"#{fid}.src"]
			begin
				if File.exist?("#{fid}.ttl")
					`sudo chown \`id -u\` #{fid}.ttl`
					to_remove << "#{fid}.ttl"
				end
			rescue 
			end
			self.remove_files(*to_remove)
			return [probes,sources]
		ensure
			f.close unless f.nil?
		end
	end
end

