# frozen_string_literal: true

require "open3"
require "tmpdir"

RSpec.describe "bin/check-commits" do
  script = File.expand_path("../../bin/check-commits", __dir__)
  noreply = "1+someone@users.noreply.github.com"

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      git("init", "-q", "-b", "main")
      commit("chore: base", email: noreply)
      example.run
    end
  end

  define_method(:identity) do |email|
    { "GIT_AUTHOR_NAME" => "a", "GIT_AUTHOR_EMAIL" => email, "GIT_COMMITTER_NAME" => "a", "GIT_COMMITTER_EMAIL" => noreply }
  end

  define_method(:git) do |*args, email: noreply|
    output, status = Open3.capture2e(identity(email), "git", *args, chdir: @dir)
    raise output unless status.success?

    output
  end

  define_method(:commit) do |message, email: noreply|
    git("commit", "-q", "--allow-empty", "-m", message, email: email)
  end

  define_method(:check_range) do
    Open3.capture2e("bash", script, "main..HEAD", chdir: @dir)
  end

  define_method(:check_message) do |message, email: noreply|
    file = File.join(@dir, "MESSAGE")
    File.write(file, message)
    Open3.capture2e(identity(email), "bash", script, "--message", file, chdir: @dir)
  end

  before { git("checkout", "-q", "-b", "work") }

  it "passes a conventional commit by the noreply address" do
    commit("fix(audit): report it")

    output, status = check_range

    expect(status).to be_success
    expect(output).to eq("")
  end

  it "refuses an author that is not the noreply address, without printing the address" do
    commit("fix: x", email: "someone@example.com")

    output, status = check_range

    expect(status).not_to be_success
    expect(output).to include("not the noreply address")
    expect(output).not_to include("someone@example.com")
  end

  it "refuses every attribution line" do
    ["Co-Authored-By: A <a@b.c>", "Claude-Session: https://x", "Generated with [Claude Code](https://x)"].each do |line|
      _output, status = check_message("fix: x\n\n#{line}\n")

      expect(status).not_to be_success, line
    end
  end

  it "accepts a body that only talks about attribution" do
    _output, status = check_message("chore: guard\n\nRefuses a co-authored-by line in a commit.\n")

    expect(status).to be_success
  end

  it "refuses a subject that is not conventional" do
    commit("arreglo cosas")

    output, status = check_range

    expect(status).not_to be_success
    expect(output).to include("not a conventional commit")
  end

  it "ignores merge commits in a range" do
    commit("fix: x")
    git("checkout", "-q", "main")
    commit("chore: other")
    git("checkout", "-q", "work")
    git("merge", "-q", "--no-edit", "main")

    _output, status = check_range

    expect(status).to be_success
  end

  it "checks the author about to commit with --message" do
    output, status = check_message("fix: x\n", email: "someone@example.com")

    expect(status).not_to be_success
    expect(output).to include("not the noreply address")
  end

  it "ignores the comment lines git leaves in a message file" do
    _output, status = check_message("fix: x\n\n# Co-Authored-By: A <a@b.c>\n")

    expect(status).to be_success
  end

  it "ignores the diff git commit -v leaves below the scissors line" do
    diff = "# ------------------------ >8 ------------------------\n# Do not modify or remove the line above.\ndiff --git a/x b/x\n+Generated with [Claude Code](https://x)\n"

    _output, status = check_message("chore: guard\n\n#{diff}")

    expect(status).to be_success
  end

  it "accepts the lowercase merge subject the history already holds" do
    _output, status = check_message("merge: main into work\n")

    expect(status).to be_success
  end

  it "accepts a merge subject with --message" do
    _output, status = check_message("Merge branch 'main' into work\n")

    expect(status).to be_success
  end
end
