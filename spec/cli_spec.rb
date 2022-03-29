# frozen_string_literal: true

describe Asciidoctor::Reducer::Cli do
  # NOTE override subject to return class object; RSpec returns instance of class by default
  subject { described_class }

  before do
    @old_stdin, $stdin = $stdin, StringIO.new
    @old_stdout, $stdout = $stdout, StringIO.new # rubocop:disable RSpec/ExpectOutput
    @old_stderr, $stderr = $stderr, StringIO.new # rubocop:disable RSpec/ExpectOutput
  end

  after do
    $stdin, $stdout, $stderr = @old_stdin, @old_stdout, @old_stderr # rubocop:disable RSpec/InstanceVariable,RSpec/ExpectOutput
  end

  let :the_input_source do
    <<~'END'
    before include

    include::multiple-paragraphs.adoc[]

    after include
    END
  end

  let :the_expected_source do
    <<~'END'
    before include

    first paragraph

    second paragraph
    with two lines

    after include
    END
  end

  context 'bin script' do
    it 'should install bin script named asciidoctor-reducer' do
      bin_script = (Pathname.new Gem.bindir) / 'asciidoctor-reducer'
      bin_script = Pathname.new Gem.bin_path 'asciidoctor-reducer', 'asciidoctor-reducer' unless bin_script.exist?
      (expect bin_script).to exist
    end

    it 'should read args from ARGV by default' do
      out, _, res = run_command asciidoctor_reducer_bin, '-v'
      (expect res.exitstatus).to eql 0
      (expect out.chomp).to eql %(asciidoctor-reducer #{Asciidoctor::Reducer::VERSION})
    end
  end

  context 'signals', unless: windows? do
    it 'should handle HUP signal gracefully' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      the_ext_file = fixture_file 'signal.rb'
      out, err, res = run_command asciidoctor_reducer_bin, '-r', the_ext_file, the_source_file, '-a', 'signal=HUP'
      (expect res.exitstatus).to (be 1).or (be 129)
      (expect out).to be_empty
      (expect err).to be_empty
    end

    it 'should handle INT signal gracefully and append line feed' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      the_ext_file = fixture_file 'signal.rb'
      out, err, res = run_command asciidoctor_reducer_bin, '-r', the_ext_file, the_source_file, '-a', 'signal=INT'
      (expect res.exitstatus).to (be 2).or (be 130)
      (expect out).to be_empty
      if jruby?
        (expect err).to be_empty
      else
        (expect err).to eql $/
      end
    end

    it 'should handle KILL signal gracefully' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      the_ext_file = fixture_file 'signal.rb'
      out, err, res = run_command asciidoctor_reducer_bin, '-r', the_ext_file, the_source_file, '-a', 'signal=KILL'
      (expect res.exitstatus).to be_nil
      (expect res.success?).to be_falsey
      (expect res.termsig).to eql 9
      (expect out).to be_empty
      (expect err).to be_empty
    end
  end

  context 'options' do
    it 'should display error message and return non-zero exit status when invalid option is specified' do
      (expect subject.run %w(--invalid)).to eql 1
      (expect $stderr.string.chomp).to eql 'asciidoctor-reducer: invalid option: --invalid'
      (expect $stdout.string.chomp).to start_with 'Usage: asciidoctor-reducer'
    end

    it 'should display program name and version when -v option is specified' do
      (expect subject.run %w(-v)).to eql 0
      (expect $stdout.string.chomp).to eql %(asciidoctor-reducer #{Asciidoctor::Reducer::VERSION})
    end

    it 'should ignore other options when -v option is specified' do
      (expect subject.run %w(-v -h)).to eql 0
      (expect $stdout.string.chomp).to eql %(asciidoctor-reducer #{Asciidoctor::Reducer::VERSION})
    end

    it 'should display help text when -h option is specified' do
      (expect subject.run %w(-h)).to eql 0
      stdout = $stdout.string.chomp
      (expect stdout).to start_with 'Usage: asciidoctor-reducer'
      (expect stdout).to include 'Reduces a composite AsciiDoc document'
      (expect stdout).to include '-h, --help'
    end

    it 'should write output to file specified by the -o option' do
      run_scenario do
        input_source the_input_source
        output_file create_output_file
        reduce { subject.run ['-o', output_file, input_file] }
        expected_source the_expected_source
      end
    end

    it 'should create empty file specified by -o option if output is empty' do
      run_scenario do
        input_source 'include::empty.adoc[]'
        output_file create_output_file
        reduce { subject.run ['-o', output_file, input_file] }
        expected_source ''
      end
    end

    it 'should write to stdout when -o option is -' do
      run_scenario do
        input_source the_input_source
        output_file $stdout
        reduce { subject.run [input_file, '-o', '-'] }
        expected_source the_expected_source
      end
    end

    it 'should exit with status code 1 when value of -o option is a directory' do
      exit_code = run_scenario do
        input_source the_input_source
        reduce { subject.run [input_file, '-o', Dir.tmpdir] }
      end
      (expect exit_code).to eql 1
      message = $stderr.string.chomp.downcase
      if message.include? 'permission'
        (expect message).to include 'permission denied'
      else
        (expect message).to include 'is a directory'
      end
    end

    it 'should allow runtime attribute to be specified using -a option' do
      run_scenario do
        input_source <<~'END'
        = Book Title

        include::{chaptersdir}/ch1.adoc[]
        END

        output_file $stdout

        reduce { subject.run [input_file, '-a', 'chaptersdir=chapters', '-a', 'doctitle=Untitled'] }

        expected_source <<~'END'
        = Book Title

        == Chapter One

        content
        END
      end
    end

    it 'should set attribute value to empty string if only name is passed to -a option' do
      run_scenario do
        input_source <<~'END'
        primary content
        ifdef::flag[]
        ifeval::["{flag}" == ""]
        conditional content
        endif::[]
        endif::flag[]
        END

        output_file $stdout

        reduce { subject.run [input_file, '-a', 'flag'] }

        expected_source <<~'END'
        primary content
        conditional content
        END
      end
    end

    it 'should reduce preprocessor conditionals by default' do
      run_scenario do
        input_source 'ifdef::asciidoctor-version[text]'
        output_file $stdout
        reduce { subject.run [input_file] }
        expected_source 'text'
      end
    end

    it 'should preserve preprocessor conditionals if --preserve-conditionals option is specified' do
      run_scenario do
        input_source 'ifdef::asciidoctor-version[text]'
        output_file $stdout
        reduce { subject.run [input_file, '--preserve-conditionals'] }
        expected_source input_source
      end
    end

    it 'should set level on logger to higher value specified by --log-level option' do
      run_scenario do
        input_source <<~'END'
        before include

        include::no-such-file.adoc[]

        after include
        END
        output_file $stdout
        reduce { subject.run [input_file, '--log-level', 'fatal'] }
        expected_source <<~END
        before include

        Unresolved directive in #{input_file_basename} - include::no-such-file.adoc[]

        after include
        END
      end
      (expect $stderr.string.chomp).to be_empty
    end

    it 'should ignore --log-level option if value is warn' do
      run_scenario do
        input_source <<~'END'
        before include

        include::no-such-file.adoc[opts=optional]

        after include
        END
        output_file $stdout
        reduce { subject.run [input_file, '--log-level', 'warn'] }
        expected_source <<~'END'
        before include


        after include
        END
      end
      (expect $stderr.string.chomp).to be_empty
    end

    it 'should set level on logger to lower value specified by --log-level option' do
      run_scenario do
        input_source <<~'END'
        before include

        include::no-such-file.adoc[opts=optional]

        after include
        END
        output_file $stdout
        reduce { subject.run [input_file, '--log-level', 'info'] }
        expected_source <<~'END'
        before include


        after include
        END
      end
      (expect $stderr.string.chomp).to include 'optional include dropped'
    end

    it 'should suppress log messages when -q option is specified' do
      run_scenario do
        input_source <<~'END'
        before include

        include::no-such-file.adoc[]

        after include
        END
        output_file $stdout
        reduce { subject.run [input_file, '-q'] }
        expected_source <<~END
        before include

        Unresolved directive in #{input_file_basename} - include::no-such-file.adoc[]

        after include
        END
      end
      (expect $stderr.string.chomp).to be_empty
    end

    it 'should require library specified by -r option' do
      run_scenario do
        input_source the_input_source
        the_ext_file = create_extension_file %(puts 'extension required'\n)
        output_file $stdout
        reduce { subject.run [input_file, '-r', the_ext_file] }
        expected_source <<~END
        extension required
        #{the_expected_source.chomp}
        END
      end
    end

    it 'should require libraries specified by single -r option' do
      run_scenario do
        input_source the_input_source
        a_ext_file = create_extension_file %(puts 'extension required'\n)
        b_ext_file = create_extension_file %(puts 'another extension required'\n)
        output_file $stdout
        reduce { subject.run [input_file, '-r', ([a_ext_file, b_ext_file].join ',')] }
        expected_source <<~END
        extension required
        another extension required
        #{the_expected_source.chomp}
        END
      end
    end

    it 'should require libraries specified by multiple -r options' do
      run_scenario do
        input_source the_input_source
        a_ext_file = create_extension_file %(puts 'extension required'\n)
        b_ext_file = create_extension_file %(puts 'another extension required'\n)
        output_file $stdout
        reduce { subject.run [input_file, '-r', a_ext_file, '-r', b_ext_file] }
        expected_source <<~END
        extension required
        another extension required
        #{the_expected_source.chomp}
        END
      end
    end

    it 'should show error message if library specified by -r cannot be required' do
      expected_message = %(asciidoctor-reducer: 'no-such-library' could not be required)
      run_scenario do
        input_source the_input_source
        output_file $stdout
        reduce { subject.run [input_file, '-r', 'no-such-library'] }
        verify do
          (example.expect result).to example.eql 1
          (example.expect $stderr.string).to example.start_with expected_message
          (example.expect $stdout.string).to example.be_empty
        end
      end
    end
  end

  context 'arguments' do
    it 'should show error message and usage and return non-zero exit status when no arguments are given' do
      expected = 'asciidoctor-reducer: Please specify an AsciiDoc file to reduce.'
      (expect subject.run []).to eql 1
      (expect $stderr.string.chomp).to eql expected
      (expect $stdout.string.chomp).to start_with 'Usage: asciidoctor-reducer'
    end

    it 'should show error message and usage and return non-zero exit status when more than one argument is given' do
      expected = 'asciidoctor-reducer: extra arguments detected (unparsed arguments: bar.adoc)'
      (expect subject.run %w(foo.adoc bar.adoc)).to eql 1
      (expect $stderr.string.chomp).to eql expected
      (expect $stdout.string.chomp).to start_with 'Usage: asciidoctor-reducer'
    end

    it 'should write to stdout when -o option is not specified' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      (expect subject.run [the_source_file]).to eql 0
      (expect $stdout.string.chomp).to include 'just good old-fashioned paragraph text'
    end

    it 'should read from stdin when argument is -' do
      $stdin.write %(include::#{fixture_file 'no-includes.adoc'}[])
      $stdin.rewind
      (expect subject.run %w(-)).to eql 0
      (expect $stdout.string.chomp).to include 'just good old-fashioned paragraph text'
    end
  end

  context 'safe mode' do
    it 'should permit file to be included in parent directory of docdir using relative path' do
      the_source_file = fixture_file 'subdir/with-parent-include.adoc'
      (expect subject.run [the_source_file]).to eql 0
      (expect $stdout.string.chomp).to include 'just good old-fashioned paragraph text'
    end

    it 'should permit file to be included in parent directory of docdir using absolute path' do
      the_source_file = fixture_file 'subdir/with-parent-include.adoc'
      (expect subject.run [the_source_file, '-a', %(includedir=#{File.dirname File.dirname the_source_file})]).to eql 0
      (expect $stdout.string.chomp).to include 'just good old-fashioned paragraph text'
    end

    it 'should not permit file to be included in parent directory of docdir when safe mode is safe' do
      the_source_file = fixture_file 'subdir/with-parent-include.adoc'
      (expect subject.run [the_source_file, '-S', 'safe']).to eql 0
      (expect $stdout.string.chomp).to include 'Unresolved directive'
      (expect $stderr.string.chomp).to include 'illegal reference to ancestor of jail'
    end
  end

  context 'error' do
    it 'should suggest --trace option if application ends in error' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      ext_source = <<~'END'
      Asciidoctor::Extensions.register do
        tree_processor do
        end
      end
      END
      with_tmp_file '.rb' do |the_ext_file|
        the_ext_file.write ext_source
        the_ext_file.flush
        (expect subject.run [the_source_file, '-r', the_ext_file.path]).to eql 1
      end
      stderr_lines = $stderr.string.chomp.lines
      (expect stderr_lines[0]).to include 'asciidoctor-reducer: FAILED: '
      (expect stderr_lines[0]).to include 'No block specified to process tree processor extension'
      (expect stderr_lines[-1]).to include 'Use --trace to show backtrace'
    ensure
      Asciidoctor::Extensions.unregister_all
    end

    it 'should show backtrace of error if --trace option is specifed' do
      the_source_file = fixture_file 'parent-with-single-include.adoc'
      ext_source = <<~'END'
      Asciidoctor::Extensions.register do
        tree_processor do
        end
      end
      END
      with_tmp_file '.rb' do |the_ext_file|
        the_ext_file.write ext_source
        the_ext_file.flush
        expect do
          subject.run [the_source_file, '-r', the_ext_file.path, '--trace']
        end.to raise_exception ArgumentError, %r/No block specified to process tree processor extension/
      end
    ensure
      Asciidoctor::Extensions.unregister_all
    end
  end
end
