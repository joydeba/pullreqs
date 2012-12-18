#!/usr/bin/env ruby

require 'rubygems'
require 'bundler'
require 'ghtorrent'
require 'time'
require 'linguist'
require 'grit'
require 'pp'

require 'java_pull_req_data'
require 'ruby_pull_req_data'
require 'scala'
require 'c'

class PullReqDataExtraction < GHTorrent::Command

  include GHTorrent::Persister
  include GHTorrent::Settings
  include Grit

  def prepare_options(options)
    options.banner <<-BANNER
Extract data for pull requests for a given repository

#{command_name} owner repo lang

    BANNER
    options.opt :extract_diffs,
                'Extract file diffs for modified files'
    options.opt :diff_dir,
                'Base directory to store file diffs', :default => "diffs"
  end

  def validate
    super
    Trollop::die "Three arguments required" unless !args[2].nil?
  end

  def logger
    @ght.logger
  end

  def db
    @db ||= @ght.get_db
    @db
  end

  def mongo
    @mongo ||= connect(:mongo, settings)
    @mongo
  end

  def repo
    @repo ||= clone(ARGV[0], ARGV[1])
    @repo
  end

  # Main command code
  def go

    @ght ||= GHTorrent::Mirror.new(settings)

    user_entry = @ght.transaction{@ght.ensure_user(ARGV[0], false, false)}

    if user_entry.nil?
      Trollop::die "Cannot find user #{owner}"
    end

    repo_entry = @ght.transaction{@ght.ensure_repo(ARGV[0], ARGV[1], false, false, false)}

    if repo_entry.nil?
      Trollop::die "Cannot find repository #{owner}/#{repo}"
    end

    case ARGV[2]
      when "ruby" then self.extend(RubyData)
      when "java" then self.extend(JavaData)
      when "c" then self.extend(CData)
      when "scala" then self.extend(ScalaData)
    end

    # Print file header
    print "pull_req_id,project_name,github_id,"<<
          "created_at,merged_at,closed_at,lifetime_minutes,mergetime_minutes," <<
          "team_size_at_merge,num_commits," <<
          "num_commit_comments,num_issue_comments,num_comments," <<
          #"files_added, files_deleted, files_modified" <<
          "files_changed," <<
          #"src_files, doc_files, other_files, " <<
          "total_commits_last_month,main_team_commits_last_month," <<
          "sloc,churn," <<
          "commits_on_files_touched," <<
          "test_lines_per_1000_lines,test_cases_per_1000_lines," <<
          "assertions_per_1000_lines\n"

    # Process the list of merged pull requests
    pull_reqs(repo_entry).each do |pr|
      begin
        process_pull_request(pr)
      rescue Exception => e
        STDERR.puts "Error processing pull_request #{pr[:github_id]}: #{e.message}"
        STDERR.puts e.backtrace
        #raise e
      end
    end
  end

  # Get a list of full requests that have been merged for the processed project
  def pull_reqs(project)
    q = <<-QUERY
    select p.name as project_name, pr.id, pr.pullreq_id as github_id,
           a.created_at as created_at, b.created_at as closed_at,
			     (select created_at
            from pull_request_history prh1
            where prh1.pull_request_id = pr.id
            and prh1.action='merged' limit 1) as merged_at,
           timestampdiff(minute, a.created_at, b.created_at) as lifetime_minutes,
			timestampdiff(minute, a.created_at, (select created_at
                                           from pull_request_history prh1
                                           where prh1.pull_request_id = pr.id and prh1.action='merged' limit 1)
      ) as mergetime_minutes
    from pull_requests pr, projects p,
         pull_request_history a, pull_request_history b
    where p.id = pr.base_repo_id
	    and a.pull_request_id = pr.id
      and a.pull_request_id = b.pull_request_id
      and a.action='opened' and b.action='closed'
	    and a.created_at < b.created_at
      and p.id = ?
	  group by pr.id
    order by closed_at desc;
    QUERY
    db.fetch(q, project[:id]).all
  end

  # Process a single pull request
  def process_pull_request(pr)

    # Statistics across pull request commits
    stats = pr_stats(pr[:id])

    merged = ! pr[:merged_at].nil?

    # Count number of src/comment lines
    src = src_lines(pr[:id].to_f)

    if src == 0 then raise Exception.new("Bad number of lines: #{0}") end

    # Print line for a pull request
    print pr[:id], ",",
          pr[:project_name], ",",
          pr[:github_id], ",",
          Time.at(pr[:created_at]).to_i, ",",
          unless merged then '' else Time.at(pr[:merged_at]).to_i end, ",",
          Time.at(pr[:closed_at]).to_i, ",",
          pr[:lifetime_minutes], ",",
          unless merged then '' else Time.at(pr[:mergetime_minutes]).to_i end, ",",
          team_size_at_merge(pr[:id], 3)[0][:teamsize], ",",
          num_commits(pr[:id])[0][:commit_count], ",",
          num_comments(pr[:id])[0][:comment_count], ",",
          num_issue_comments(pr[:id])[0][:issue_comment_count], ",",
          num_comments(pr[:id])[0][:comment_count] + num_issue_comments(pr[:id])[0][:issue_comment_count], ",",
          #stats[:files_added], ",",
          #stats[:files_deleted], ",",
          #stats[:files_modified], ",",
          stats[:files_added] + stats[:files_modified] + stats[:files_deleted], ",",
          #stats[:src_files], ",",
          #stats[:doc_files], ",",
          #stats[:other_files], ",",
          commits_last_month(pr[:id], false)[0][:num_commits], ",",
          commits_last_month(pr[:id], true)[0][:num_commits], ",",
          src, ",",
          stats[:lines_added] + stats[:lines_deleted], ",",
          commits_on_files_touched(pr[:id], Time.at(Time.at(unless merged then pr[:closed_at] else pr[:merged_at] end).to_i - 3600 * 24 * 30)), ",",
          (test_lines(pr[:id]).to_f / src.to_f) * 1000, ",",
          (num_test_cases(pr[:id]).to_f / src.to_f) * 1000, ",",
          (num_assertions(pr[:id]).to_f / src.to_f) * 1000,
          "\n"

    if options[:extract_diffs]
      FileUtils.mkdir_p(File.join(options[:diff_dir], pr[:project_name], pr[:github_id].to_s))

      file_diffs(pr[:id]).each {|f|
        num = 0
        repo.log(f[:latest], f[:filename])[0..f[:num_versions]].map{|x| x.sha}.each { |sha|
          d = repo.tree(sha, f[:filename]).blobs[0].data
          filename = f[:filename].gsub("/","-") + "-" + sha[0..10] + "." + num.to_s
          file = File.open(File.join(options[:diff_dir],
                                  pr[:github_id].to_s, filename), "w")
          file.write(d)
          file.close
          num += 1
        }
      }
    end

  end

  # Number of developers that have committed at least once in the interval
  # between the pull request merge up to +interval_months+ back
  def team_size_at_merge(pr_id, interval_months)
    q = <<-QUERY
    select count(distinct author_id) as teamsize
    from projects p, commits c, project_commits pc, pull_requests pr,
         pull_request_history prh
    where p.id = pc.project_id
      and pc.commit_id = c.id
      and p.id = pr.base_repo_id
      and prh.pull_request_id = pr.id
      and not exists (select * from pull_request_commits prc1 where prc1.commit_id = c.id)
      and prh.action = IF(IFNULL((select id from pull_request_history where action='merged' and pull_request_id=pr.id), 1) <> 1, 'merged', 'closed')
      and c.created_at < prh.created_at
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL #{interval_months} MONTH)
      and pr.id=?;
    QUERY
    not_zero(if_empty(db.fetch(q, pr_id).all, :teamsize), :teamsize)
  end

  # Number of commits in pull request
  def num_commits(pr_id)
    q = <<-QUERY
    select count(*) as commit_count
    from pull_requests pr, pull_request_commits prc
    where pr.id = prc.pull_request_id
      and pr.id=?
    group by prc.pull_request_id
    QUERY
    if_empty(db.fetch(q, pr_id).all, :commit_count)
  end

  # Number of src code review comments in pull request
  def num_comments(pr_id)
    q = <<-QUERY
    select count(*) as comment_count
    from pull_requests pr, pull_request_comments prc
    where pr.id = prc.pull_request_id
	    and pr.id = ?
    group by prc.pull_request_id
    QUERY
    if_empty(db.fetch(q, pr_id).all, :comment_count)
  end

  # Number of pull request discussion comments
  def num_issue_comments(pr_id)
    q = <<-QUERY
    select count(*) as issue_comment_count
    from issue_comments ic, issues i
    where ic.issue_id=i.id
    and pull_request_id is not null
    and i.pull_request_id=?;
    QUERY
    if_empty(db.fetch(q, pr_id).all, :issue_comment_count)
  end

  # Number of followers of the person that created the pull request
  def requester_followers(pr_id)
    q = <<-QUERY
    select count(f.follower_id) as num_followers
    from pull_requests pr, followers f, pull_request_history prh
    where pr.user_id = f.user_id
      and prh.pull_request_id = pr.id
      and prh.action = 'merged'
      and f.created_at < prh.created_at
      and pr.id = ?
    QUERY
    if_empty(db.fetch(q, pr_id).all, :num_followers)
  end

  # Various statistics for the pull request. Returned as Hash with the following
  # keys: :lines_added, :lines_deleted, :files_added, :files_removed,
  # :files_modified, :files_touched, :src_files, :doc_files, :other_files.
  def pr_stats(pr_id)

    raw_commits = commit_entries(pr_id)
    result = Hash.new(0)

    def file_count(commit, status)
      commit['files'].reduce(0) { |acc, y|
        if y['status'] == status then acc + 1 else acc end
      }
    end

    def file_type(f)
      lang = Linguist::Language.detect(f, nil)
      if lang.nil? then :data else lang.type end
    end

    def file_type_count(commit, type)
      commit['files'].reduce(0) { |acc, y|
        if file_type(y['filename']) == type then acc + 1 else acc end
      }
    end

    raw_commits.each{ |x|
      next if x.nil?
      result[:lines_added] += x['stats']['additions']
      result[:lines_deleted] += x['stats']['deletions']
      result[:files_added] += file_count(x, "added")
      result[:files_removed] += file_count(x, "removed")
      result[:files_modified] += file_count(x, "modified")
      result[:files_touched] += (file_count(x, "modified") + file_count(x, "added") + file_count(x, "removed"))
      result[:src_files] += file_type_count(x, :programming)
      result[:doc_files] += file_type_count(x, :markup)
      result[:other_files] += file_type_count(x, :data)
    }
    result
  end

  # Number of commits on the files touched by the pull request during the
  # last month
  def commits_on_files_touched(pr_id, oldest)
    commits = commit_entries(pr_id)
    parent_commits = commits.map { |c|
      if c.nil?
        next
      end
      c['parents'].map { |x| x['sha'] }
    }.flatten.uniq

    commits.flat_map { |c| # Create sha, filename pairs
      c['files'].map { |f|
        [c['sha'], f['filename']]
      }
    }.group_by { |c|      # Group them by filename
      c[1]
    }.flat_map { |k, v|
      if v.size > 1       # Find first commit not in the pull request set
        [v.find { |x| not parent_commits.include?(x[0])}]
      else
        v
      end
    }.map { |c|
      if c.nil?
        0 # File has been just added
      else
        repo.log(c[0], c[1]).find_all { |l| # Get all commits per file newer than +oldest+
          l.authored_date > oldest
        }.size
      end
    }.flatten.reduce(0) { |acc, x| acc + x }  # Count the total number of commits
  end

  # Total number of commits on the project in the month before the pull request
  # was merged. The second parameter controls whether commits from other
  # pull requests should be accounted for
  def commits_last_month(pr_id, exclude_pull_req)
    q = <<-QUERY
    select count(c.id) as num_commits
    from projects p, commits c, project_commits pc, pull_requests pr,
         pull_request_history prh
    where p.id = pc.project_id
      and pc.commit_id = c.id
      and p.id = pr.base_repo_id
      and prh.pull_request_id = pr.id
      and prh.action = 'merged'
      and c.created_at < prh.created_at
      and c.created_at > DATE_SUB(prh.created_at, INTERVAL 1 MONTH)
      and pr.id=?
    QUERY

    if exclude_pull_req
      q << " and not exists (select * from pull_request_commits prc1 where prc1.commit_id = c.id)"
    end
    q << ";"

    if_empty(db.fetch(q, pr_id).all, :num_commits)
  end

  def file_diffs(pr_id)
    commit_entries(pr_id).map { |c|
      # For each commit
      c['files'].select { |f|
        # Select modified files
        f['status']=="modified"
      }.flatten.\
      # Create a tuple of the form [sha, filename]
      map { |x|
        [c['sha'], x['filename']]
      }
    }.\
    # Flatten tuples across commits
    reduce([]) { |acc, x| acc += x }.
    # Create a hash of commits per filename indexed by filename
    group_by{|e| e[1]}.\
    # Map result to a Hash
    map { |k,v|
      commits = v.map{|x| x[0]}#.unshift("master")
      # Find the latest point in the commit log that contains
      # all commits to a file
      latest = commits.find{|sha|
        l = repo.log(sha, k).map{|x| x.sha}
        a = commits.reduce(true){|acc,x| acc &= l.include?(x)}
        a
      }

      # Find the latest commit that in
      #latest = log.find{|e| not v.find{|x| x[0] == e.sha}.nil?}
      if latest.nil?
        fail
      end
      {
          :latest  => latest,
          :num_versions => v.size,
          :filename => k
      }
    }
  end

  private

  # JSON objects for the commits included in the pull request
  def commit_entries(pr_id)
    q = <<-QUERY
    select c.sha as sha
    from pull_requests pr, pull_request_commits prc, commits c
    where pr.id = prc.pull_request_id
    and prc.commit_id = c.id
    and pr.id = ?
    QUERY
    commits = db.fetch(q, pr_id).all

    commits.map{ |x|
      mongo.find(:commits, {:sha => x[:sha]})[0]
    }
  end

  # List of files in a project checkout. Filter is an optional binary function
  # that takes a file entry and decides whether to include it in the result.
  def files_at_commit(pr_id, filter = lambda{true})
    q = <<-QUERY
    select c.sha
    from pull_requests p, commits c
    where c.id = p.base_commit_id
    and p.id = ?
    QUERY

    base_commit = db.fetch(q, pr_id).all[0][:sha]
    files = repo.lstree(base_commit, :recursive => true)

    files.select{|x| filter.call(x)}
  end

  def if_empty(result, field)
    if result.nil? or result.empty?
      [{field => 0}]
    else
      result
    end
  end

  def not_zero(result, field)
    if result[0][field].nil? or result[0][field] == 0
      raise Exception.new("Field #{field} cannot have value 0")
    else
      result
    end
  end

  def count_lines(files, exclude_filter = lambda{true})
    files.map{ |f|
      count_file_lines(repo.blob(f[:sha]).data.lines, exclude_filter)
    }.reduce(0){|acc,x| acc + x}
  end

  def count_file_lines(buff, exclude_filter = lambda{true})
    buff.select {|l|
      not l.strip.empty? and exclude_filter.call(l)
    }.size
  end

  # Clone or update, if already cloned, a git repository
  def clone(user, repo)

    def spawn(cmd)
      proc = IO.popen(cmd, "r")

      proc_out = Thread.new {
        while !proc.eof
          logger.debug "#{proc.gets}"
        end
      }

      proc_out.join
    end

    checkout_dir = File.join(config(:cache_dir), "repos", user, repo)

    begin
      repo = Grit::Repo.new(checkout_dir)
      spawn("cd #{checkout_dir} && git pull")
      repo
    rescue
      spawn("git clone git://github.com/#{user}/#{repo}.git #{checkout_dir}")
      Grit::Repo.new(checkout_dir)
    end
  end

  def count_multiline_comments(file_str, comment_regexp)
    file_str.scan(comment_regexp).map { |x|
      x.lines.count
    }.reduce(0){|acc, x| acc + x}
  end

  def count_single_line_comments(file_str, comment_regexp)
    file_str.split("\n").select {|l|
      l.match(comment_regexp)
    }.size
  end

  def src_files(pr_id)
    raise Exception.new("Unimplemented")
  end

  def src_lines(pr_id)
    raise Exception.new("Unimplemented")
  end

  def test_files(pr_id)
    raise Exception.new("Unimplemented")
  end

  def test_lines(pr_id)
    raise Exception.new("Unimplemented")
  end

  def num_test_cases(pr_id)
    raise Exception.new("Unimplemented")
  end

  def num_assertions(pr_id)
    raise Exception.new("Unimplemented")
  end
end

PullReqDataExtraction.run
#vim: set filetype=ruby expandtab tabstop=2 shiftwidth=2 autoindent smartindent: