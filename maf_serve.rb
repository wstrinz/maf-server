require 'sinatra'
require 'sinatra/streaming'
require 'open-uri'
require 'bio-publisci'
require 'cgi'

helpers do
  def clear_store
    `sudo killall 4s-backend`
    `sudo killall 4s-httpd`
    `sudo 4s-backend setup test`
    `sudo 4s-backend test`
    `sudo 4s-httpd -U test`
  end
end

configure do
  set :processing_status, :idle
end

get '/' do
  "Some sort of homepage"
end

get '/input' do
  @remote_maf = "https://tcga-data.nci.nih.gov/tcgafiles/ftp_auth/distro_ftpusers/anonymous/tumor/brca/gsc/genome.wustl.edu/illuminaga_dnaseq/mutations/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0.somatic.maf"
  haml :input
end

post '/input' do
  stream do |out|
    @remote_maf = params[:remote_maf]
    out.puts "downloading #{@remote_maf}<br>"
    open(@remote_maf){|f|
      File.open('downloaded_temp.maf','w'){|fi| fi.write f.read}
    }

    out.puts "removing quotes<br>"
    # Remove quotes...
    file = open('downloaded.maf','w')
    open('downloaded_temp.maf','r'){|f|
      f.each_line do |line|
        file.write line.gsub('"','')
      end
    }

    file.close

    out.puts "File downloaded! check the <a href='wait_for_it'>Status</a> page for progress<br>"
    Thread.new do
      raise "Can only handle one job at a time, try again later" unless settings.processing_status == :idle || settings.processing_status["Error"] || settings.processing_status == ["Done!"]
      begin
        settings.processing_status = "Triplifying input"
        parser = PubliSci::Readers::MAF.new
        parser.generate_n3('downloaded.maf',{dataset_name: "maf_data"})
        settings.processing_status = "Clearing the store"
        clear_store
        settings.processing_status = "Loading the data into 4store"
        repo = RDF::FourStore::Repository.new('http://localhost:8080')
        repo.load('downloaded.maf', :format => :ttl)
        settings.processing_status = "Done!"
      rescue => description
        settings.processing_status = "Error: #{description.inspect}, #{CGI.escapeHTML(description.backtrace.join("\n"))}"
      end
    end
  end
  # haml :input
end

get '/interact' do

end

post '/interact' do

end

get '/query' do

end

post '/query' do

end

get '/status' do
  "Its #{settings.processing_status} <br>"
end

get '/wait_for_it' do
  stream do |out|
    out.puts "Waiting for results<br>"
    current = settings.processing_status
    out.puts "#{current}<br>"
    until settings.processing_status == "Done!"
      if settings.processing_status != current
        current = settings.processing_status
        out.puts "#{current}<br>"
      else
        out.puts "."
      end
      sleep(10)
    end

    
    out.puts "All Done!<br>"
  end
end