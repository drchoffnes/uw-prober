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

#! /usr/bin/ruby
require 'net/http' 
require 'optparse'
require 'resolv'

require "vp_config.rb"

begin
	require 'prober'
rescue LoadError 
	# lets us bootstrap the initial version that broke out prober.rb
	begin
		$stderr.puts `date +%Y/%m/%d.%H%M.%S`.chomp("\n") + " " + "Unable to load prober: #{$!.class} #{$!.to_s}"
		$stderr.puts `date +%Y/%m/%d.%H%M.%S`.chomp("\n") + " " + "Trying to download prober source."
		source = Net::HTTP.get_response(URI.parse('http://revtr.cs.washington.edu/vps/prober.rb')).body
		$stderr.puts `date +%Y/%m/%d.%H%M.%S`.chomp("\n") + " " +  "Preparing to write prober.rb"
		File.open("prober.rb", File::CREAT|File::TRUNC|File::WRONLY, 0644){|f|
			f.puts source
		}
		require 'prober'
	rescue LoadError,RuntimeError
		$stderr.puts `date +%Y/%m/%d.%H%M.%S`.chomp("\n") + " " + "EXITING: Unable to load prober: #{$!.class} #{$!.to_s}"
		Kernel.exit(6)
	end
end

# issues: race condition on the target file, always named the same
# should kill by pid, maybe, instead of killall
# - have a thread that registers, then goes to sleep
# - rrping always creates the same output file, so do some of the others, a
# race unless i run rrping from a new directory
# actually, seems like it might be based on where you start vantage_point.rb
# can do $? to get exit status of system calls.	 should i be returning this to
# the user too?


# if the uid used for spoofed tr is out of range
class OutOfRangeError < RuntimeError
	attr_reader :min, :max, :value
	def initialize(min, max,value)
		@min,@max,@value=min,max,value
	end

	def to_s
		super + ": #{@value} not in (#{@min}..#{@max})"
	end
end

class VantagePoint < Prober
	# allows controller to call back to issue measurements, etc
	include DRbUndumped
	VP_VERSION = "$Id: vantage_point.rb,v 1.81 2012/08/02 14:38:50 revtr Exp $".split(" ").at(2).to_f

	include VantagePointConfig
	UPDATE_INFO = { 
		:prober => 	{ 
			:fn => 'prober.rb',
			:curr_source => URI.parse('http://revtr.cs.washington.edu/vps/prober.rb'),
			:curr_version => URI.parse('http://revtr.cs.washington.edu/vps/prober_version.txt'),
			:version => PROBER_VERSION
		},
		:vp => 	{ 
			:fn => 'vantage_point.rb',
			:curr_source => URI.parse('http://revtr.cs.washington.edu/vps/vantage_point.rb'),
			:curr_version => URI.parse('http://revtr.cs.washington.edu/vps/vantage_point_version.txt'),
			:version => VP_VERSION
		},
		:vp_config => {
			:fn => 'vp_config.rb',
			:curr_source => URI.parse('http://revtr.cs.washington.edu/vps/vp_config.rb'),
			:curr_version => URI.parse('http://revtr.cs.washington.edu/vps/vp_config_version.txt'),
			:version => VP_CONFIG_VERSION
		}
	}

	# if controller_uri is nil, will fetch from the default location
	# if not using an acl, will start_service no matter what
	# if using acl, will start service if @controller_uri is assigned without
	# exceptions being thrown
	def initialize(controller_uri,use_acl,front_prober,port,proberoute_dir,output_dir=Prober::DEFAULT_TMP_OUTPUT_DIR)
		super(proberoute_dir,output_dir)
		@pid2fn = {}
		@front_prober=front_prober
		@port=port
		# setting in case we can't get the controller uri below
		# and it doesn't get set properly
		# need it set to something true so we know to use acl in the
		# future
		@acl=use_acl
		@controller_uri=nil
		begin
			if controller_uri.nil?
				controller_uri = Prober::get_default_controller_uri
			end
		rescue
			self.log("Unable to fetch controller uri:",$!)
		end
		begin
			if controller_uri.nil?
				self.register
			else
				update_controller(controller_uri)
			end
		rescue
			self.log("Unable to register:",$!)
		end
	end

	attr_reader :controller_uri
	
	# starts_service if not started already (unless we are using an ACL AND we
	# don't have a controller uri)
	# may throw exceptions
	# returns nil if successful, else raises an exception
	def register(controller=nil)
		if self.drb.nil?
			if not @acl
				self.start_service(nil,@front_prober,@port)
			elsif @controller_uri
				@acl=Prober::build_acl(@controller_uri)
				self.start_service(@acl,@front_prober,@port)
			else
				self.log("Not starting service: ACL required, but no controller uri")
			end
		end
		if controller.nil?
			if @controller_uri.nil?
				raise RuntimeError, "Missing URI for controller", caller
			end
			controller=DRbObject.new nil, @controller_uri
		end
		controller.register(self)
		return nil
	end

	# may throw exceptions.
	def unregister
		if @controller_uri
			(DRbObject.new nil, @controller_uri).unregister(self)
		end
	end

	def stop_service
		begin
			self.unregister
		rescue
			self.log("Unable to unregister when stopping service: #{$!.class} #{$!}\n#{$!.backtrace.join("\n")}")
		ensure
			super
		end
	end

	def version
		return VantagePoint::VP_VERSION
	end

	# if no controller, don't update
	# if same controller, don't update
	# if new controller, try to unregister, then register with new one
	def update_controller(uri)
		if uri.nil? or uri.length==0
			self.log "Not updating controller: nil"
			return
		end

		if uri!=@controller_uri
			self.log "Updating from controller #{@controller_uri} to #{uri}"
			if not @controller_uri.nil?
				begin
					# if we need to build a new ACL, we have to stop the service first
					if (@acl && Prober::uri2host(uri)!=Prober::uri2host(@controller_uri))
						self.log("Stopping service for new ACL\n#{ Prober::build_acl(uri)}\n#{self.drb.config[:tcp_acl]}")
						self.stop_service
					else
						self.log("Unregistering for new controller")
						self.unregister
					end
				rescue
					self.log "Exception: Unable to unregister from #{@controller_uri} #{$!.to_s}", $VP_ERROR
				end
			end
			@controller_uri=uri
			self.register
		end
	end

	$RESTART=12
	$UPGRADE_RESTART=11
	# lets us kill it remotely
	# overrides Prober.shutdown to include the upgrade options
	# but is that right, or should it unregister while shutting down?
	def shutdown(code=0)
		self.log "Exiting: Received shutdown message #{code}"
# 		begin
# 			if code==$UPGRADE_RESTART
# 				self.log "Upgrading, so not unregistering"
# 			elsif code==$RESTART
# 				self.log "Restarting without upgrade"
# 			else
# 				self.unregister
# 			end
#		ensure
		super.shutdown(code)
#		end
	end

	def restart
		Kernel::system("sudo /usr/sbin/atd; echo \"sleep 10; ./vantage_point.rb 1>> #{$LOG_FILE} 2>&1 \"|at now")
		sleep 2
		self.log "Shutting down for restart"
		self.shutdown($RESTART)

	end

	# whether an upgrade to this version from an earlier one requires a
	# restart
	# should be set to false, unless a particular version needs it
	# doing it as a method in case we ever need more logic in it
	def restart_vp?
		true
	end


	# returns true if it updated
	def check_for_update(component=:vp)
		updated=false
		begin
		self.log "Checking for newer version of #{UPDATE_INFO[component][:fn]}...."
			current_version = Net::HTTP.get_response(UPDATE_INFO[component][:curr_version]).body.to_f
			if current_version==0.0
				self.log "Error: Unable to fetch number of current version"
				# we check != rather than > bc w cvs versions, 1.2 comes before 1.11
				# assumption is that the webpage will always have the version we want
				# to run
			elsif current_version!=UPDATE_INFO[component][:version]
				self.log "Upgrading from #{UPDATE_INFO[component][:version]} to #{current_version}"
				code = Net::HTTP.get_response(UPDATE_INFO[component][:curr_source]).body
				self.log "Preparing to write version #{current_version}"
				File.open(UPDATE_INFO[component][:fn], File::CREAT|File::TRUNC|File::WRONLY, 0755){|f|
					f.puts code
				}
				self.log "Wrote version #{current_version}"
				load(UPDATE_INFO[component][:fn])
                load(UPDATE_INFO[:vp_config][:fn])
				updated=true
				UPDATE_INFO[component][:version]=current_version
				self.log "Upgraded to version #{UPDATE_INFO[component][:version]}"
					# sleep 10 to give this one a chance to shut down - only
					# one can run at a time
					# Kernel::system("sudo /usr/sbin/atd; echo \"sleep 10; ./vantage_point.rb 1>> #{$LOG_FILE} 2>&1 \"|at now")
					# self.log "Shutting down for upgrade to version #{current_version}"
					# sleep 2
					# self.shutdown($UPGRADE_RESTART)
			else
				self.log "No upgrade available from #{UPDATE_INFO[component][:version]}"
			end
		rescue
			self.log "Unable to check for update: #{$!.class}: #{$!.to_s}\n#{$!.backtrace.join("\n")}"
		end
		return updated
	end


	# execute a system call, return stdout
	def backtic(cmd)  
		self.log "VantagePoint::backtic: running \`#{cmd}\`"
		return Kernel::`(cmd) 
		# `
	end

	# not positive this always works correctly with 3+ params
	def system(cmd,*params)
		self.log "VantagePoint::system: running \"#{cmd} #{params.join(" ")}\""
		return Kernel::system(cmd,*params)
	end

	def get_results( pid )
		files = @pid2fn[pid]
		files.each { |file| `sudo chown \`id -u\` #{file}` }
		output = `if [ \`ps -p #{pid} | grep -c #{files.at(0)}\` == 0 ] ; then echo \"process completed\" >> #{$LOG_FILE};\ else echo \"killing pid #{pid}\" >> #{$LOG_FILE} ; kill -9 #{pid} ; fi`
		f=nil
		probes=nil
		begin
			f=File.new(files.at(0))
			probes=f.read
			self.remove_files(*files)
			return probes
		ensure
			f.close unless f.nil?
		end
	end

	def launch_traceroute( targs )
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		pid=IO.popen("sudo /usr/sbin/atd; echo \"sudo #{@proberoute_dir}/randstprober #{Prober::PROBING_THREADS} #{fn} #{@device} 1 #{fn}.trace.out #{fn}.count.out\" | at now").pid
		@pid2fn[pid]=["#{fn}.trace.out", "#{fn}.count.out", fn]
		return pid
	end

	def launch_ping( targs )
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		pid=IO.popen("sudo /usr/sbin/atd; echo \"sudo #{@proberoute_dir}/aliasprobe #{Prober::PROBING_THREADS} #{fn} #{@device} > #{fn}.out\" | at now").pid
		@pid2fn[pid]=["#{fn}.out", fn]
		return pid
	end

	def launch_rr( targs )
		fn=create_target_file{|targ_file| targ_file.puts targs.join("\n")}
		pid=IO.popen("sudo /usr/sbin/atd; echo \"sudo #{@proberoute_dir}/rrping #{Prober::PROBING_THREADS} #{fn} #{@device} #{fn}.rrping.out\" | at now").pid
		@pid2fn[pid]=["#{fn}.rrping.out", "#{fn}.rrping.out.ttl",fn]
		return pid
	end

	def launch_ts( probes )
		fn=create_target_file{|targ_file| probes.each{|probe| targ_file.puts probe.join(" ")}}
		pid=IO.popen("sudo /usr/sbin/atd; echo \"sudo #{@proberoute_dir}/tsprespec-ping  #{Prober::PROBING_THREADS} #{fn} #{@device} > #{fn}.out\" | at now").pid        
		@pid2fn[pid]=["#{fn}.out", fn]
		return pid
	end

	# probes is hash[receiver] -> [tr1, tr2, ...]
	# tr is either dst, [dst], [dst, start_ttl], or [dst, start_ttl, end_ttl]
	# if ttls aren't given, will do 1..30
	# id is the spoofer ID to put into the probes
	# must be at most 11 bits
	def spoof_tr(probes, id)
		if id>2047  or id<0
			raise OutOfRangeError.new(0,2047,id), "Spoofer ID out of range"
		end
		fn=create_target_file{|targf|
			probes.keys.each{|rec|
				trs=probes[rec]
				$stderr.puts "sending spoofed traceroute ID=#{id} as #{rec} " + trs.collect{|x| x.join(",")}.join(" ") 
				trs.each{|tr|
					case tr
					when Array
						dst=tr.at(0)
						case tr.length
						when 1
							start,finish=1,30
						when 2
							start,finish=tr.at(1),30
						else
							start,finish=tr.at(1),tr.at(2)
						end
					when String
						dst,start,finish=tr,1,30
					end
					if start<1 or start>finish
						raise OutOfRangeError.new(1,finish,start), "Start TTL out of range"
					end
					if finish>31 
						raise OutOfRangeError.new(start,31,finish), "Finish TTL out of range"
					end
					(start..finish).each{|ttl|
						targf.puts "#{dst} #{ttl} #{rec}"
					}
				}
			}
		}
		`sudo #{@proberoute_dir}/pingspoof #{Prober::PROBING_THREADS} #{fn} #{@device} #{id}`
		self.remove_files(fn)
	end
end

# this lets us load in new versions of the class without rerunning the code
# below
if not $started
	$started=true

	$stderr.puts "Version number #{VantagePoint::VP_VERSION}"
	if `ps aux|grep vantage_point.rb|grep ruby|grep -v grep|wc -l`.to_i>1
			$stderr.puts "Already running"
			$stderr.puts `ps aux|grep vantage_point.rb `
			Kernel.exit(17)
	end


	# Hash will include options parsed by OptionParser.
	options = Hash.new

	optparse = OptionParser.new do |opts|
		options[:acl] = true
		opts.on( '-A', '--no-acl', 'Disable access control list.  Otherwise, only allows connections from localhost and from the host specified in the controller URI.' ) do
			options[:acl] = false
		end
		options[:controller_uri] = nil
		opts.on( '-cURI', '--controller=URI', "Controller URI (default={fetch from #{Prober::CONTROLLER_INFO}})") do|f|
			  options[:controller_uri] = f
		end
		options[:backoff] = true
		opts.on( '-d', '--destination-probing', 'Enable destination probing.  Overrides default assumption that first hop from destination symmetric.' ) do
			options[:backoff] = false
		end
		options[:front] = true
		opts.on( '-F', '--no-front', 'Do not front the prober with DRb.' ) do
			options[:front] = false
		end
		opts.on( '-h', '--help', 'Display this screen' ) do
			puts("Usage: #{$0} [OPTION]... DESTINATION1 [DESTINATION2]...")
			puts opts.to_s.split("\n")[1..-1].join("\n")
			exit
		end
		options[:output_dir] = Prober::DEFAULT_TMP_OUTPUT_DIR
		opts.on( '-oPATH', '--out=PATH', "Temp output path PATH (default=#{Prober::DEFAULT_TMP_OUTPUT_DIR})") do|f|
			  options[:output_dir] = f
		end
		options[:port] = Prober::DEFAULT_PORT
		opts.on( '-pPORT', '--port=PORT', Integer, "Port for RPC calls (default=#{Prober::DEFAULT_PORT})") do|i|
			  options[:port] = i
		end

		options[:proberoute_dir] = Prober::DEFAULT_PROBEROUTE_DIR
		opts.on( '-tPATH', '--tools=PATH', "Probe tool path PATH (default=#{Prober::DEFAULT_PROBEROUTE_DIR})") do|f|
			  options[:proberoute_dir] = f
		end
		opts.on( '-v', '--version', 'Version') do
			puts VantagePoint::VP_VERSION
			puts Prober::PROBER_VERSION
			exit
		end
	end

	# parse! parses ARGV and removes any options found there, as well as params to
	# the options
	optparse.parse!

	vp=VantagePoint.new(options[:controller_uri],options[:acl], options[:front], options[:port], options[:proberoute_dir],options[:output_dir])
	Signal.trap("INT"){ vp.shutdown(2) }
	Signal.trap("TERM"){ vp.shutdown(15) }
	Signal.trap("KILL"){ vp.shutdown(9) }

	# # We need the uri of the service to connect a client
	$stderr.puts vp.uri

	sleep 5
	vp.log("Preparing to check for updates")
	update_thread=Thread.new(){
		while true
			begin
				$stderr.puts
				vp.log("Checking for updates")
				update_prober=vp.check_for_update(:prober)
				restart_prober=update_prober && vp.restart_prober?
				restart_vp=vp.check_for_update(:vp) && vp.restart_vp? 
				restart_config = vp.check_for_update(:vp_config)
				restart=restart_vp || restart_prober || restart_config
				vp.log("Checked for update.  Restart: #{restart}")
				if restart
					vp.stop_service
					vp=VantagePoint.new(options[:controller_uri],options[:acl], options[:front], options[:port], options[:proberoute_dir],options[:output_dir])
				end
			rescue
	 			vp.log "Exception: Can't check for update #{$!.to_s}\n" + $!.backtrace.join("\n"), $VP_ERROR
			ensure
				sleep(36000 + rand(36000))
			end
		end
	}

	# if we started with a test controller, don't need to check for new URIs
	if options[:controller_uri].nil?
		register_thread=Thread.new(){
			failed=0
			while true
				# sleep above the begin so that retry won't hit it automatically
				sleep(3600 + rand(3600))
				begin
					if failed>0
						vp.update_controller(Prober::get_default_controller_uri)
					end
					vp.register
					# if we get here without an exception, set failed=0
					failed=0
				rescue Exception
					failed += 1
					if failed==1
						vp.log "Exception: Can't update or register #{failed} times, retrying #{$!.class} #{$!.to_s}\n" + $!.backtrace.join("\n"), $VP_ERROR
						sleep(120 + (rand 120 ))
						sleep(rand(10))
						retry
					else
						vp.log "Exception: Can't update or register #{failed} times, sleeping #{$!.class} #{$!.to_s}\n" + $!.backtrace.join("\n"), $VP_ERROR
					end
				end
			end
		}
	end

	begin
		$stderr.puts "joining"
		update_thread.join
		$stderr.puts "thread dead"
	rescue
	end
	vp.shutdown(0)
	# DRb might not start properly in certain cases, so want something else to
	# wait on, possible.  
end  #if not $started
