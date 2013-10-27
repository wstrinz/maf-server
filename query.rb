require 'publisci'
require 'json'

class MafQuery
    QUERIES_DIR = Gem::Specification.find_by_name("bio-publisci").gem_dir + "/resources/queries"
    RESTRICTIONS = {
      patient: '<http://onto.strinz.me/properties/patient_id>',
      sample: '<http://onto.strinz.me/properties/sample_id>',
      gene: '<http://onto.strinz.me/properties/Hugo_Symbol>',
    }

    def generate_data
      generator = PubliSci::Readers::MAF.new
      in_file = Gem::Specification.find_by_name("bio-publisci").gem_dir + '/resources/maf_example.maf'
      f = Tempfile.new('graph')
      f.close
      generator.generate_n3(in_file, {output: :file, output_base: f.path})
      repo = RDF::Repository.load(f.path+'.ttl')
      File.delete(f.path+'.ttl')
      f.unlink
      repo
    end

    def to_por(solution)
      if solution.is_a?(Fixnum) or solution.is_a?(String) or solution.is_a?(Hash)
        solution
      elsif solution.is_a? RDF::Query::Solutions
        to_por solution.map{|sol|
          if sol.bindings.size == 1
            to_por(sol.bindings.first.last)
          else
            to_por(sol)
          end
        }
      elsif solution.is_a? RDF::Query::Solution
        if solution.bindings.size == 1
          to_por(solution.bindings.first.last)
        else
          Hash[solution.bindings.map{|bind,result| [bind,to_por(result)] }]
        end
      elsif solution.is_a? Array
        if solution.size == 1
          to_por(solution.first)
        else
          solution.map{|sol| to_por(sol)}
        end
      else
        if solution.is_a? RDF::Literal
          solution.object
        elsif solution.is_a? RDF::URI
          solution.to_s
        else
          puts "don't recognzize #{solution.class}"
          solution.to_s
        end
      end
    end

    def select_patient_count(repo,patient_id="A8-A08G")
      qry = IO.read(QUERIES_DIR + '/patient.rq')
      qry = qry.gsub('%{patient}',patient_id)

      SPARQL::Client.new("#{repo.uri}/sparql/").query(qry)
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

    def select_property(repo,property="Hugo_Symbol",restrictions={})
      property = Array(property)
      selects = property
      property = property.map{|prop|
        RESTRICTIONS[prop.to_sym] || "<http://onto.strinz.me/properties/#{prop}>"
      }
      
      targets = ""
      property.each_with_index{|p,i|
        targets << "\n  #{p} ?#{selects[i]} ;"
      }

      str = ""
      restrictions.each{|restrict,value|
        prop = RESTRICTIONS[restrict.to_sym] || "<http://onto.strinz.me/properties/#{restrict}>"
        if value.is_a? String
          if RDF::Resource(value).valid?
            if(value[/http:\/\//])
              value = RDF::Resource(value).to_base
            end
          else
            value = '"' + value + '"'
          end
        end
        str << "\n  #{prop} #{value} ;"
      }


      qry = <<-EOF
      PREFIX qb:   <http://purl.org/linked-data/cube#>
      PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
      PREFIX sio: <http://semanticscience.org/resource/>

      SELECT DISTINCT ?#{selects.join(" ?")} WHERE {
        ?obs a qb:Observation;
        #{str}
        #{targets} 
        .
      }
      EOF


      # IO.read(QUERIES_DIR + '/maf_column.rq').gsub('%{patient}',patient_id)
      results = SPARQL::Client.new("#{repo.uri}/sparql/").query(qry) #.map(&:column).map{|val| 
        # if val.is_a?(RDF::URI) and val.to_s["node"]
        #   node_value(repo,val)
        # else
        #   val
        # end

#      }.flatten
      
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
      if hugo_symbol[/ENSG\d.+/]
        ensemble_id = hugo_symbol
      else
        qry = IO.read(QUERIES_DIR + '/hugo_to_ensembl.rq').gsub('%{hugo_symbol}',hugo_symbol)
        sparql = SPARQL::Client.new("http://cu.hgnc.bio2rdf.org/sparql")
        sol = sparql.query(qry)

        if sol.size == 0
          puts "No Ensembl entry found for #{hugo_symbol}"
          return -1
        else
          ensemble_id = sol.map(&:ensembl).first.to_s.split(':').last
        end
      end

      url = URI.parse('http://beta.rest.ensembl.org/')
      http = Net::HTTP.new(url.host, url.port)
      request = Net::HTTP::Get.new('/lookup/id/' + ensemble_id + '?format=full', {'Content-Type' => 'application/json'})
      response = http.request(request)

      if response.code != "200"
        puts "Invalid response: #{response.code}"
        return -1
      else
        js = JSON.parse(response.body)
        js['end'] - js['start']
      end
    end

    def patient_info(id,repo,&block)
      symbols = Array(to_por(select_property(repo,"Hugo_Symbol",patient: id)))

      symbols = symbols.map(&:to_s).map{|sym|
        official = official_symbol(sym.split('/').last)
        if official.size > 0
          sym.split('/')[0..-2].join('/') + '/' + official
        else
          sym
        end
      }

      # patient_id = select_property(repo,"patient_id",id).first.to_s
      patient = {patient_id: id, mutation_count: symbols.size, mutations:[]}
      if block_given?
        yield patient
        symbols.each{|sym| yield Hash(symbol: sym, length: gene_length(sym)) }
      else
        symbols.each{|sym| patient[:mutations] << {symbol: sym, length: gene_length(sym)}}
      end

      patient
    end

    def gene_info(hugo_symbol,repo)
      qry = IO.read(QUERIES_DIR + '/patients_with_mutation.rq').gsub('%{hugo_symbol}',hugo_symbol)
      sols = SPARQL::Client.new("#{repo.uri}/sparql/").query(qry)
      patient_count = sols.size
      {mutations: patient_count, gene_length: gene_length(hugo_symbol), patients: sols.map(&:patient_id).map(&:to_s)}
      # symbols = select_property(repo,"Hugo_Symbol",id).map(&:to_s)
      # patient_id = select_property(repo,"patient_id",id).first.to_s
      # patient = {patient_id: patient_id, mutation_count: symbols.size, mutations:[]}

      # symbols.each{|sym| patient[:mutations] << {symbol: sym, length: gene_length(sym)}}
      # patient
    end
end

class QueryScript
  class Query
    def initialize(string,repo,template={})
      @query = string
      @repo = repo
      @template = template
    end

    def template
      @template
    end

    def substitute!
      @template.each{|k,v|
        @query.gsub!("{{#{k}}}",v)
      }
    end

    def substitute
      str = @query.dup
      @template.each{|k,v|
        str.gsub!("{{#{k}}}",v)
      }
      str
    end

    def run(template={})
      @template = @template.merge(template)
      substitute!
      SPARQL::Client.new("#{@repo.uri}/sparql/").query(@query)
    end
  end

  def initialize(script=nil,repo=nil)
    @__script = script
    @__maf = MafQuery.new
    unless repo
      @__repo = RDF::FourStore::Repository.new('http://localhost:8080')
    else
      @__repo = repo
    end
  end

  def maf_eval(script=@__script)
    @__maf.instance_eval(script)
  end

  def run_script(script=@__script)
    instance_eval(script)
  end

  def query(string,template={})
    Query.new(string,@__repo,template)
  end

  def select(operation,args={})
    @__maf.to_por(select_raw(operation,args))
  end

  def select_raw(operation, args={})
    if operation.is_a? Query
      operation.run
    elsif @__maf.methods.include?(:"select_#{operation}")
      @__maf.send(:"select_#{operation}",@__repo,args)
    else
      @__maf.select_property(@__repo,operation,args)
    end
  end

  def gene_length(gene)
    @__maf.to_por(@__maf.gene_length(gene))
  end

  def report_for(type, id)
    @__maf.send(:"#{type}_info",id, @__repo)
  end
end

# describe QueryScript do
#   describe ".select" do
#     before(:all){
#       @ev = QueryScript.new
#     }
    
#     it { @ev.select('patient_count', "BH-A0HP").should > 0 }
#     it { @ev.select('Chromosome', 'BH-A0HP').first.class.should be Fixnum}
  
#     context "with instance_eval" do
#       it { @ev.instance_eval("select 'patient_count', 'BH-A0HP'").should > 0 }
#       it { @ev.instance_eval("select 'Hugo_Symbol', 'BH-A0HP'").first.should == "http://identifiers.org/hgnc.symbol/ARHGAP30" }
#       it { @ev.instance_eval("select 'Chromosome', 'BH-A0HP'").first.class.should be Fixnum}
#       # it { @ev.instance_eval("report_for 'patient', 'BH-A0HP'").is_a?(Hash).should be true }
#     end
#   end
# end
