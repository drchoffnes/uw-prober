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
require 'yaml'
require 'open-uri'

module ProberConfig

        # URI to fetch current controller port from
        CONTROLLER_INFO="http://revtr.cs.washington.edu/vps/registrar.txt"

        # path of proberoute probing tools
        DEFAULT_PROBEROUTE_DIR="./"

        # path to put temporary output
        DEFAULT_TMP_OUTPUT_DIR="/tmp/"

        # default port for DRb
        DEFAULT_PORT=54321

        # number of threads to use in probing tools
        PROBING_THREADS = 40
        counter = 0
        begin

        vp_name = `hostname`.strip
        rate2vp = YAML::load(open('http://revtr.cs.washington.edu/vps/RateLimit.txt'))

        if rate2vp.include?(vp_name)
            PROBING_THREADS = rate2vp[vp_name].to_i
        end

        rescue

        counter += 1

        if counter < 3
            sleep 2
            retry
        end

        end

        TEST_IP="128.208.2.159"
end

$LOG_FILE="/tmp/vp_log.txt"
$VP_ERROR=2

module VantagePointConfig
        VP_CONFIG_VERSION = "$Id: vp_config.rb,v 1.5 2012/08/02 14:50:03 revtr Exp $".split(" ").at(2).to_f


end
