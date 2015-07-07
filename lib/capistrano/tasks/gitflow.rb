namespace :gitflow do
  def last_tag_matching(pattern)
    # search for most recent (chronologically) tag matching the passed pattern, then get the name of that tag.
    last_tag = `git describe --exact-match  --tags --match='#{pattern}' $(git log --tags='#{pattern}*' -n1 --pretty='%h')`.chomp
    last_tag == '' ? nil : last_tag
  end

  def last_staging_tag()
    last_tag_matching('staging-*')
  end

  def ask_confirm(message, default)
    default_text=  default.nil? ? '' : "(#{default})"
    $stdout.print "#{message}: #{default_text}"
    $stdin.gets.to_s.chomp
  end
  
  def next_staging_tag
    hwhen  = Date.today.to_s
    who = `whoami`.chomp.to_url
    what = ask_confirm("What does this release introduce? (this will be normalized and used in the tag for this release) ", nil)
  
    abort "No tag has been provided: #{what.inspect}" if what == ''
    
    last_staging_tag = last_tag_matching("staging-#{hwhen}-*")
    new_tag_serial = if last_staging_tag && last_staging_tag =~ /staging-[0-9]{4}-[0-9]{2}-[0-9]{2}\-([0-9]*)/
                       $1.to_i + 1
                     else
                       1
                     end

    "#{fetch(:stage)}-#{hwhen}-#{new_tag_serial}-#{who}-#{what.to_url}"
  end

  def last_production_tag()
    last_tag_matching('production-*')
  end

  def using_git?
    fetch(:scm, :git).to_sym == :git
  end

  task :verify_up_to_date do
    if using_git?
      set :local_branch, `git branch --no-color 2> /dev/null | sed -e '/^[^*]/d'`.gsub(/\* /, '').chomp
      set :local_sha, `git log --pretty=format:%H HEAD -1`.chomp
      set :origin_sha, `git log --pretty=format:%H #{fetch(:local_branch)} -1`
      unless fetch(:local_sha) == fetch(:origin_sha)
        abort """
Your #{fetch(:local_branch)} branch is not up to date with origin/#{fetch(:local_branch)}.
Please make sure you have pulled and pushed all code before deploying:

git pull origin #{fetch(:local_branch)}
# run tests, etc
git push origin #{fetch(:local_branch)}

"""
      end
    end
  end

  desc "Calculate the tag to deploy"
  task :calculate_tag do
    if using_git?
      # make sure we have any other deployment tags that have been pushed by others so our auto-increment code doesn't create conflicting tags
      `git fetch`
      if Rake::Task["gitflow:tag_#{fetch(:stage)}"].present?
        Rake::Task["gitflow:tag_#{fetch(:stage)}"].invoke
        
        system "git push --tags origin #{fetch(:local_branch)}"
        if $? != 0
          abort "git push failed"
        end
      else
          puts "Will deploy tag: #{fetch(:local_branch)}"
          set :branch, fetch(:local_branch)
      end
    end
  end

  desc "Show log between most recent staging tag (or given tag=XXX) and last production release."
  task :commit_log do
    from_tag = if fetch(:stage) == :production
                 last_production_tag
               elsif fetch(:stage) == :staging
                 last_staging_tag
               else
                 abort "Unsupported stage #{fetch(:stage)}"
               end

    # no idea how to properly test for an optional cap argument a la '-s tag=x'
    to_tag = capistrano_configuration[:tag]
    to_tag ||= begin
                 puts "Calculating 'end' tag for :commit_log for '#{fetch(:stage)}'"
                 to_tag = if fetch(:stage) == :production
                            last_staging_tag
                          elsif fetch(:stage) == :staging
                            'master'
                          else
                            abort "Unsupported stage #{fetch(:stage)}"
                          end
               end


    # use custom compare command if set
    if ENV['git_log_command'] && ENV['git_log_command'].strip != ''
        command = "git #{ENV['git_log_command']} #{from_tag}..#{to_tag}"
    else
        # default compare command
        # be awesome for github
        if `git config remote.origin.url` =~ /git@github.com:(.*)\/(.*).git/
            command = "open https://github.com/#{$1}/#{$2}/compare/#{from_tag}...#{to_tag}"
        else
            command = "git log #{from_tag}..#{to_tag}"
        end
    end
    puts "Displaying commits from #{from_tag} to #{to_tag} via:\n#{command}"
    system command

    puts ""
  end

  desc "Mark the current code as a staging/qa release"
  task :tag_staging do
    current_sha = `git log --pretty=format:%H HEAD -1`
    last_staging_tag_sha = if last_staging_tag
                             `git log --pretty=format:%H #{last_staging_tag} -1`
                           end

    if last_staging_tag_sha == current_sha
      puts "Not re-tagging staging because latest tag (#{last_staging_tag}) already points to HEAD"
      new_staging_tag = last_staging_tag
    else
      new_staging_tag = next_staging_tag
      puts "Tagging current branch for deployment to staging as '#{new_staging_tag}'"
      system "git tag -a -m 'tagging current code for deployment to staging' #{new_staging_tag}"
    end

    set :branch, new_staging_tag
  end

  desc "Push the approved tag to production. Pass in tag to deploy with '-s tag=staging-YYYY-MM-DD-X-feature'."
  task :tag_production do
    promote_to_production_tag = capistrano_configuration[:tag] || last_staging_tag

    unless promote_to_production_tag && promote_to_production_tag =~ /staging-.*/
      abort "Couldn't find a staging tag to deploy; use '-s tag=staging-YYYY-MM-DD.X'"
    end
    unless last_tag_matching(promote_to_production_tag)
      abort "Staging tag #{promote_to_production_tag} does not exist."
    end

    promote_to_production_tag =~ /^staging-(.*)$/
    new_production_tag = "production-#{$1}"

    if new_production_tag == last_production_tag
      puts "Not re-tagging #{last_production_tag} because it already exists"
      really_deploy = ask_confirm("Do you really want to deploy #{last_production_tag}? [y/N]", "N")

     exit(1) unless really_deploy.to_url =~ /^[Yy]$/
    else
      puts "Preparing to promote staging tag '#{promote_to_production_tag}' to '#{new_production_tag}'"
      gitflow.commit_log
      unless capistrano_configuration[:tag]
        really_deploy = ask_confirm("Do you really want to deploy #{new_production_tag}? [y/N]", "N")

        exit(1) unless really_deploy.to_url =~ /^[Yy]$/
      end
      puts "Promoting staging tag #{promote_to_production_tag} to production as '#{new_production_tag}'"
      system "git tag -a -m 'tagging current code for deployment to production' #{new_production_tag} #{promote_to_production_tag}"
    end

    set :branch, new_production_tag
  end
  
 before "deploy", "gitflow:calculate_tag"
 after "gitflow:calculate_tag", "gitflow:verify_up_to_date"
end

namespace :deploy do
  namespace :pending do
    task :compare do
      gitflow.commit_log
    end
  end
end

