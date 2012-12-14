module ScalaData

  def num_test_cases(pr_id)
    0
  end

  def num_assertions(pr_id)
    0
  end

  def test_lines(pr_id)
    0
  end

  def test_files(pr_id)
    0
  end

  def src_files(pr_id)
    files_at_commit(pr_id,
      lambda { |f|
        f[:path].end_with?('.scala') and not f[:path].include?("/test/")
      }
    )
  end

  def src_lines(pr_id)
    count_sloc(src_files(pr_id))
  end

  private

  def count_sloc(files)
    files.map { |f|
      buff = repo.blob(f[:sha]).data
      # Count lines except empty ones
      count_file_lines(buff.lines, lambda{|l| not l.strip.empty?}) -
          count_single_line_comments(buff, /^\s*\/\//) -
          count_multiline_comments(buff, /\/\*(?:.|[\r\n])*?\*\//)
    }.reduce(0){|acc, x| acc + x}
  end
end