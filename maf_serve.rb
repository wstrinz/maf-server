require 'sinatra'
require 'open-uri'
require 'bio-publisci'

get '/' do
  "Some sort of homepage"
end

get '/input' do
  @remote_maf = "https://tcga-data.nci.nih.gov/tcgafiles/ftp_auth/distro_ftpusers/anonymous/tumor/brca/gsc/genome.wustl.edu/illuminaga_dnaseq/mutations/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0/genome.wustl.edu_BRCA.IlluminaGA_DNASeq.Level_2.5.3.0.somatic.maf"
  haml :input
end

post '/input' do
  @remote_maf = params[:remote_maf]
  puts "downloading #{@remote_maf}"
  open(@remote_maf){|f|
    File.open('downloaded.maf','w'){|fi| fi.write f.read}
  }
  puts "parsing file"
  parser = PubliSci::Readers::MAF.new
  parser.generate_n3('downloaded.maf',{dataset_name: "maf_data"})
  puts "Clearing the store"
  repo = RDF::FourStore::Repository.new('http://localhost:8080')
  puts "loading file"
  repo.load(f.path, :format => :ttl)
  haml :input
end

get '/interact' do

end

post '/interact' do

end

get '/query' do

end

post '/query' do

end