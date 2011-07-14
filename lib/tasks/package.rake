require 'erb'

def get_version
  `git describe`.strip
end

def get_temp
  `mktemp -d`.strip
end

def get_name
  'puppet-dashboard'
end

def add_version_file(path)
  sh "echo #{get_version} > #{path}/VERSION"
end

def update_redhat_spec_file(base)
  name = get_name
  spec_date = Time.now.strftime("%a %b %d %Y")
  release = ENV['RELEASE'] ||= "1"
  version = get_version
  rpmversion = version.gsub('-', '_')
  specfile = File.join(base, 'ext', 'packaging', 'redhat', "#{name}.spec")
  erbfile = File.join(base, 'ext', 'packaging', 'redhat', "#{name}.spec.erb")
  template = IO.read(erbfile)
  message = ERB.new(template, 0, "-")
  output = message.result(binding)
  holder = `mktemp`.strip!
  File.open(holder, 'w') {|f| f.write(output) }
  mv holder , specfile
  rm_f erbfile
end

def update_debian_changelog(base)
  name = get_name
  dt = Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")
  version = get_version
  version.gsub!('v', '')
  deb_changelog = File.join(base, 'ext', 'packaging', 'debian', 'changelog')
  erbfile = File.join(base, 'ext', 'packaging', 'debian', 'cl.erb')
  template = IO.read(erbfile)
  message = ERB.new(template, 0, "-")
  output = message.result(binding)
  holder = `mktemp`.strip!
  sh "echo -n \"#{output}\" | cat - #{deb_changelog}  > #{holder}"
  mv holder, deb_changelog
  rm_f erbfile
end

def prep_rpm_builds
  name=get_name
  version=get_version
  temp=`mktemp -d`.strip!
  raise "No /usr/bin/rpmbuild found!" unless File.exists? '/usr/bin/rpmbuild'
  dirs = [ 'BUILD', 'SPECS', 'SOURCES', 'RPMS', 'SRPMS' ]
  dirs.each do |d|
    FileUtils.mkdir_p "#{temp}//#{d}"
  end
  rpm_defines = " --define \"_specdir #{temp}/SPECS\" --define \"_rpmdir #{temp}/RPMS\" --define \"_sourcedir #{temp}/SOURCES\" --define \" _srcrpmdir #{temp}/SRPMS\" --define \"_builddir #{temp}/BUILD\""
  sh "tar zxvf  pkg/tar/#{name}-#{version}.tar.gz  --no-anchored ext/packaging/redhat/#{name}.spec"
  mv "#{name}-#{version}/ext/packaging/redhat/#{name}.spec",  "#{temp}/SPECS"
  rm_rf "#{name}-#{version}"
  sh "cp pkg/tar/*.tar.gz #{temp}/SOURCES"
  return [ temp,  rpm_defines ]
end

namespace :package do
  desc "Create .deb from this git repository, set KEY_ID=your_key to use a specific key or UNSIGNED=1 to leave unsigned."
  task :deb => :tar  do
    name = get_name
    version = get_version
    dt = Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")
    temp=`mktemp -d`.strip!
    base="#{temp}/#{name}-#{version}"
    sh "cp pkg/tar/#{name}-#{version}.tar.gz #{temp}"
    cd temp do
      sh "tar zxf *.tar.gz"
      cd "#{name}-#{version}" do
        mv File.join('ext', 'packaging', 'debian'), '.'
        cmd = 'dpkg-buildpackage -a'
        cmd << ' -us -uc' if ENV['UNSIGNED'] == '1'
        cmd << " -k#{ENV['KEY_ID']}" if ENV['KEY_ID']
        begin
          sh cmd
          dest_dir = File.join(RAILS_ROOT, 'pkg', 'deb')
          mkdir_p dest_dir
          cp latest_file(File.join(temp, '*.deb')), dest_dir
          cp latest_file(File.join(temp, '*.dsc')), dest_dir
          cp latest_file(File.join(temp, '*.changes')), dest_dir
          puts
          puts "** Created package: "+ latest_file(File.expand_path(File.join(RAILS_ROOT, 'pkg', 'deb', '*.deb')))
        rescue
          puts <<-HERE
!! Building the .deb failed!
!! Perhaps you want to run:

    rake package:deb UNSIGNED=1

!! Or provide a specific key id, e.g.:

    rake package:deb KEY_ID=4BD6EC30
    rake package:deb KEY_ID=me@example.com

          HERE
        end
      end
    end
      rm_rf temp
  end

  desc "Create srpm from this git repository (unsigned)"
  task :srpm => :tar do
    name = get_name
    version = get_version
    temp,  rpm_defines = prep_rpm_builds
    sh "rpmbuild #{rpm_defines} -bs --nodeps #{temp}/SPECS/*.spec"
    mkdir_p "#{RAILS_ROOT}/pkg/srpm"
    sh "mv -f #{temp}/SRPMS/* pkg/srpm"
    rm_rf temp
    puts
    puts "** Created package: "+ latest_file(File.expand_path(File.join(RAILS_ROOT, 'pkg', 'srpm', '*.rpm')))
  end

  desc "Create .rpm from this git repository (unsigned)"
  task :rpm => :srpm do
    name = get_name
    version = get_version
    temp, rpm_defines = prep_rpm_builds
    sh "rpmbuild #{rpm_defines} -ba #{temp}/SPECS/*.spec"
    mkdir_p "#{RAILS_ROOT}/pkg/srpm"
    mkdir_p "#{RAILS_ROOT}/pkg/rpm"
    sh "mv -f #{temp}/SRPMS/* pkg/srpm"
    sh "mv -f #{temp}/RPMS/*/*rpm pkg/rpm"
    rm_rf temp
    puts
    puts "** Created package: "+ latest_file(File.expand_path(File.join(RAILS_ROOT, 'pkg', 'rpm', '*.rpm')))
  end


  desc "Create a release .tar.gz"
  task :tar => :build_environment do
    name = get_name
    rm_rf 'pkg/tar'
    temp=`mktemp -d`.strip!
    version = `git describe`.strip!
    base = "#{temp}/#{name}-#{version}/"
    mkdir_p base
    sh "git checkout-index -af --prefix=#{base}"
    add_version_file(base)
    update_redhat_spec_file(base)
    update_debian_changelog(base)
    mkdir_p "pkg/tar"
    sh "tar -C #{temp} -p -c -z -f #{temp}/#{name}-#{version}.tar.gz #{name}-#{version}"
    mv "#{temp}/#{name}-#{version}.tar.gz",  "#{RAILS_ROOT}/pkg/tar"
    rm_rf temp
    puts
    puts "Tarball is #{RAILS_ROOT}/pkg/tar/#{name}-#{version}.tar.gz"
  end

  task :build_environment do
    unless ENV['FORCE'] == '1'
      modified = `git status --porcelain | sed -e '/^\?/d'`
      if modified.split(/\n/).length != 0
        puts <<-HERE
!! ERROR: Your git working directory is not clean. You must
!! remove or commit your changes before you can create a package:

#{`git status | grep '^#'`.chomp}

!! To override this check, set FORCE=1 -- e.g. `rake package:deb FORCE=1`
        HERE
        raise
      end
    end
  end

  # Return the file with the latest mtime matching the String filename glob (e.g. "foo/*.bar").
  def latest_file(glob)
    require 'find'
    return FileList[glob].map{|path| [path, File.mtime(path)]}.sort_by(&:last).map(&:first).last
  end

end
