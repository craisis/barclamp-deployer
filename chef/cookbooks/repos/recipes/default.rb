# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

provisioners = search(:node, "roles:provisioner-server")
provisioner = provisioners[0] if provisioners
os_token="#{node[:platform]}-#{node[:platform_version]}"

file "/tmp/.repo_update" do
  action :nothing
end

if provisioner and (provisioner[:provisioner][:repositories][os_token] || nil rescue nil)
  web_port = provisioner["provisioner"]["web_port"]
  proxy = "http://#{provisioner.address.addr}:8123/"
  online = provisioner["provisioner"]["online"] rescue nil
  repositories = provisioner["provisioner"]["repositories"][os_token]

  case node["platform"]
  when "ubuntu","debian"
    cookbook_file "/etc/apt/apt.conf.d/99-crowbar-no-auth" do
      source "apt.conf"
    end
    file "/etc/apt/sources.list" do
      action :delete
    end unless online
    template "/etc/apt/apt.conf.d/00-proxy" do
      source "apt-proxy.erb"
      variables(:proxy => proxy)
    end
    repositories.each do |repo,urls|
      case
      when repo == "base"
        template "/etc/apt/sources.list.d/00-base.list" do
          variables(:urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      when repo =~ /.*_online/
        template "/etc/apt/sources.list.d/20-barclamp-#{repo}.list" do
          source "10-crowbar-extra.list.erb"
           variables(:urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      else
        template "/etc/apt/sources.list.d/10-barclamp-#{repo}.list" do
          source "10-crowbar-extra.list.erb"
          variables(:urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      end
    end if repositories
    bash "update software sources" do
      code "apt-get update"
      notifies :delete, "file[/tmp/.repo_update]", :immediately
      only_if { ::File.exists? "/tmp/.repo_update" }
    end
    package "rubygems"
  when "redhat","centos"
    bash "update software sources" do
      code "yum clean expire-cache"
      action :nothing
    end
    bash "add yum proxy" do
      code "echo proxy=#{proxy} >> /etc/yum.conf"
      not_if "grep -q '^proxy=http' /etc/yum.conf"
    end
    bash "Disable fastestmirror plugin" do
      code "sed -i '/^enabled/ s/1/0/' /etc/yum/pluginconf.d/fastestmirror.conf"
      only_if "test -f /etc/yum/pluginconf.d/fastestmirror.conf"
    end
    bash "Reenable main repos" do
      code "yum -y reinstall centos-release"
      not_if "test -f /etc/yum.repos.d/CentOS-Base.repo"
      notifies :create, "file[/tmp/.repo_update]", :immediately
    end if online && (node[:platform] == "centos")
    repositories.each do |repo,urls|
      case
      when repo =~ /.*_online/
        rpm_sources, bare_sources = urls.keys.partition{|r|r =~ /^rpm /}
        bare_sources.each do |source|
          _, name, _, url = source.split
          url = "baseurl=#{url}" if url =~ /^http/
          template "/etc/yum.repos.d/crowbar-#{repo}-#{name}.repo" do
            source "crowbar-xtras.repo.erb"
            variables(:repo => name, :urls => {url => true})
            notifies :create, "file[/tmp/.repo_update]", :immediately
          end
        end
        rpm_sources.each do |repo|
          url = repo.split(' ',2)[1]
          file = url.split('/').last
          file = file << ".rpm" unless file =~ /\.rpm$/
          bash "fetch /var/cache/#{file}" do
            not_if "test -f '/var/cache/#{file}'"
            code <<EOC
export http_proxy=http://#{provisioner.address.addr}:8123
curl -o '/var/cache/#{file}' -L '#{url}'
rpm -Uvh '/var/cache/#{file}'
EOC
            notifies :create, "file[/tmp/.repo_update]", :immediately
          end
        end
      else
        template "/etc/yum.repos.d/crowbar-#{repo}.repo" do
          source "crowbar-xtras.repo.erb"
          variables(:repo => repo, :urls => urls)
          notifies :create, "file[/tmp/.repo_update]", :immediately
        end
      end
    end if repositories
    bash "update software sources" do
      code "yum clean expire-cache"
      notifies :delete, "file[/tmp/.repo_update]", :immediately
      only_if { ::File.exists? "/tmp/.repo_update" }
    end
  end
  template "/etc/gemrc" do
    variables(:online => online,
              :admin_ip => provisioner.address.addr,
              :web_port => web_port,
              :proxy => proxy)
  end
end

