require 'bio-publisci'
require 'json'

class MafQuery
    QUERIES_DIR = Gem::Specification.find_by_name("bio-publisci").gem_dir + "/resources/queries"


    # def generate_data
    #   generator = PubliSci::Readers::MAF.new
    #   in_file = 'resources/maf_example.maf'
    #   f = Tempfile.new('graph')
    #   f.close
    #   generator.generate_n3(in_file, {output: :file, output_base: f.path})
    #   repo = RDF::Repository.load(f.path+'.ttl')
    #   File.delete(f.path+'.ttl')
    #   f.unlink
    #   repo
    # end

    def select_patient_count(repo,patient_id="A8-A08G")
      qry = IO.read(QUERIES_DIR + '/patient.rq')
      qry = qry.gsub('%{patient}',patient_id)

      SPARQL::Client.new("#{repo.uri}/sparql/").query(qry).first[:barcodes].to_i
    end

    def patients(repo)
      qry = IO.read(QUERIES_DIR + '/patient_list.rq')
      SPARQL::Client.new("#{repo.uri}/sparql/").query(qry).map(&:id).map(&:to_s)
    end

    def select_patient_genes(repo,patient_id="A8-A08G")
      qry = IO.read(QUERIES_DIR + '/gene.rq')
      qry = qry.gsub('%{patient}',patient_id)
      SPARQL::Client.new("#{repo.uri}/sparql/").query(qry)
    end

    def select_property(repo,property="hgnc.symbol",patient_id="A8-A08G")
      qry = IO.read(QUERIES_DIR + '/maf_column.rq').gsub('%{patient}',patient_id).gsub('%{column}',property)
      results = SPARQL::Client.new("#{repo.uri}/sparql/").query(qry).map(&:column).map{|val| 
        if val.is_a?(RDF::URI) and val.to_s["node"]
          node_value(repo,val)
        else
          val
        end

      }.flatten

    end

    def node_value(repo,uri)
      qry = "SELECT DISTINCT ?p ?o where { <#{uri.to_s}> ?p ?o}"
      SPARQL::Client.new("#{repo.uri}/sparql/").query(qry).map{|sol|
        if sol[:p].to_s == "http://semanticscience.org/resource/SIO_000300"
          sol[:o]
        elsif sol[:p].to_s == "http://semanticscience.org/resource/SIO_000008"
          qry = "SELECT DISTINCT ?p ?o where { <#{sol[:o].to_s}> ?p ?o}"
          SPARQL::Client.new("#{repo.uri}/sparql/").query(qry).select{|sol| sol[:p].to_s == "http://semanticscience.org/resource/SIO_000300"}.first[:o]
        elsif sol[:p].to_s != "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
          sol[:o]
        end
      }.reject{|sol| sol == nil}
    end

    def official_symbol(hugo_symbol)
      qry = <<-EOF

      SELECT distinct ?official where {
       {?hgnc <http://bio2rdf.org/hgnc_vocabulary:approved_symbol> "#{hugo_symbol}"}
       UNION
       {?hgnc <http://bio2rdf.org/hgnc_vocabulary:synonym> "#{hugo_symbol}"}

       ?hgnc <http://bio2rdf.org/hgnc_vocabulary:approved_symbol> ?official
      }

      EOF

      sparql = SPARQL::Client.new("http://cu.hgnc.bio2rdf.org/sparql")
      sparql.query(qry).map(&:official).first.to_s
    end

    def gene_length(hugo_symbol)
      hugo_symbol = hugo_symbol.split('/').last
      qry = IO.read(QUERIES_DIR + '/hugo_to_ensembl.rq').gsub('%{hugo_symbol}',hugo_symbol)
      sparql = SPARQL::Client.new("http://cu.hgnc.bio2rdf.org/sparql")
      sol = sparql.query(qry)

      if sol.size == 0
        puts "No Ensembl entry found for #{hugo_symbol}"
        return -1
      else
        ensemble_id = sol.map(&:ensembl).first.to_s.split(':').last
      end

      url = URI.parse('http://beta.rest.ensembl.org/')
      http = Net::HTTP.new(url.host, url.port)
      request = Net::HTTP::Get.new('/lookup/id/' + ensemble_id + '?format=full', {'Content-Type' => 'application/json'})
      response = http.request(request)

      if response.code != "200"
        raise "Invalid response: #{response.code}"
      else
        js = JSON.parse(response.body)
        js['end'] - js['start']
      end
    end

    def patient_info(id,repo)
      symbols = select_property(repo,"Hugo_Symbol",id).map(&:to_s).map{|sym|
        official = official_symbol(sym.split('/').last)
        if official.size > 0
          sym.split('/')[0..-2].join('/') + '/' + official
        else
          sym
        end
      }
      patient_id = select_property(repo,"patient_id",id).first.to_s
      patient = {patient_id: patient_id, mutation_count: symbols.size, mutations:[]}

      symbols.each{|sym| patient[:mutations] << {symbol: sym, length: gene_length(sym)}}
      patient
    end
end