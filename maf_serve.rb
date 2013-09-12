require 'sinatra'
require 'sinatra/streaming'
require 'open-uri'
require 'bio-publisci'
require 'cgi'
require_relative 'query.rb'

helpers do
  def clear_store
    pass = IO.read('passfile').chomp
    puts `echo #{pass} | sudo -S killall 4s-backend`
    puts `echo #{pass} | sudo -S killall 4s-httpd`
    puts `echo #{pass} | sudo -S 4s-backend-setup test`
    puts `echo #{pass} | sudo -S 4s-backend test`
    puts `echo #{pass} | sudo -S 4s-httpd -U test`
  end

  def run_script(script)
    QueryScript.new(script).run_script
  end

  def h(html)
    CGI::escapeHTML(html.to_s)
  end
end

configure do
  set :processing_status, :idle
end

get '/' do
  redirect 'input'
end

get '/input' do
  @remote_maf = "https://tcga-data.nci.nih.gov/tcgafiles/ftp_auth/distro_ftpusers/anonymous/tumor/brca/gsc/genome.wustl.edu/illuminaga_dnaseq/mutations/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0.somatic.maf"
  haml :input
end

post '/input' do
  raise "Can only handle one job at a time, try again later" unless settings.processing_status == :idle || settings.processing_status["Error"] || settings.processing_status["Done!"]
  stream do |out|
    @remote_maf = params[:remote_maf]
    out.puts "downloading #{@remote_maf}<br><br>"
    out.puts "Check the <a href='wait_for_it'>Status</a> page for progress<br>"
    Thread.new do
      begin
        settings.processing_status = "Downloading remote file"
        
        open(@remote_maf){|f|
          File.open('downloaded_temp.maf','w'){|fi| fi.write f.read}
        }

        settings.processing_status = "Removing quotes"
        file = open('downloaded.maf','w')
        open('downloaded_temp.maf','r'){|f|
          f.each_line do |line|
            file.write line.gsub('"','')
          end
        }

        file.close

        settings.processing_status = "Triplifying input"
        parser = PubliSci::Readers::MAF.new
        parser.generate_n3('downloaded.maf',{dataset_name: "maf_data"})
        settings.processing_status = "Clearing the store"
        clear_store
        settings.processing_status = "Loading the data into 4store"
        repo = RDF::FourStore::Repository.new('http://localhost:8080')
        repo.load('downloaded.ttl', :format => :ttl)
        settings.processing_status = "Done!"
      rescue => description
        settings.processing_status = "Error: #{description.inspect}, #{CGI.escapeHTML(description.backtrace.join("\n"))}"
      end
    end
  end
  # haml :input
end

get '/patients' do
  queryer = MafQuery.new
  result = queryer.patients(RDF::FourStore::Repository.new('http://localhost:8080'))
  result.map{|res| "<a href='patient/#{res.to_s}'>#{res.to_s}</a>"}.join('<br>')
end

get '/patient/:id' do
  # generate patient report
  stream do |out|
    content_type :json
    
    patient = params[:id]
    queryer = MafQuery.new
    queryer.patient_info(patient,RDF::FourStore::Repository.new('http://localhost:8080')){|ret|
      out.puts ret.to_json
    }
  end
end

get '/genes' do
  queryer = MafQuery.new
  result = queryer.select_property(RDF::FourStore::Repository.new('http://localhost:8080'),'Hugo_Symbol')
  result.map{|res| "<a href='gene/#{res.to_s.split('/').last}'>#{res.to_s.split('/').last}</a>"}.join('<br>')
end

get '/gene/:id' do
  stream do |out|
    content_type :json

    gene = params[:id]

    queryer = MafQuery.new
    result = queryer.gene_info(gene,RDF::FourStore::Repository.new('http://localhost:8080'))
    out.puts result.to_json
  end
end

get '/query' do
  @query = params[:query] || <<-EOF

# Select patients with a mutation in SHANK1

PREFIX qb:   <http://purl.org/linked-data/cube#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX sio: <http://semanticscience.org/resource/>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

SELECT DISTINCT ?patient_id WHERE {
  [] a qb:ComponentSpecification;
    rdfs:label "Hugo_Symbol";
    qb:measure ?hugo_symbol.

  [] a qb:ComponentSpecification;
    rdfs:label "patient_id";
    qb:measure ?patient_id_property.

  ?obs a qb:Observation;
    ?hugo_symbol [ sio:SIO_000300 <http://identifiers.org/hgnc.symbol/SHANK1> ];
    ?patient_id_property ?patient_id .
}

  EOF
  @repo = RDF::FourStore::Repository.new('http://localhost:8080')

  haml :query
end

post '/query' do
  @query = params[:query]
  @repo = RDF::FourStore::Repository.new('http://localhost:8080')
  @result = SPARQL::Client.new("#{@repo.uri}/sparql/").query(@query)
  str = '<table border="1">'
  @result.map{|solution|
    str << "<tr>"
    solution.bindings.map{|bind,result|
      str << "<td>" + CGI.escapeHTML("#{bind}:  #{result.to_s}") + "</td>"
    }
    str << "</tr>"
  }
  str << "</table>"
  @result = str

  haml :query
end

get '/script' do
  @script = params[:script] || "select 'Hugo_Symbol', 'BH-A0HP'"

  haml :script
end

post '/script' do
  @script = params[:script]
  @result = run_script(params[:script])

  haml :script
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

    
    out.puts "All Done!<br><br>"
    out.puts "<a href='patients'>View Patients</a><br>"
    out.puts "<a href='genes'>View Genes</a><br>"
  end
end