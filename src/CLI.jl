# Copyright 2018 IBM Corp.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

""" Command-line interface for raw and semantic flow graphs.
"""
module CLI
export main, invoke, parse

using ArgParse
import DefaultApplication
using Requires
import JSON
import Serd

using Catlab.WiringDiagrams, Catlab.Graphics
import Catlab.Graphics: Graphviz
using ..RawFlowGraphs
using ..Ontology, ..SemanticEnrichment
using ..Serialization

# CLI arguments
###############

const settings = ArgParseSettings()

@add_arg_table settings begin
  "record"
    help = "record code as raw flow graph"
    action = :command
  "enrich"
    help = "convert raw flow graph to semantic flow graph"
    action = :command
  "visualize"
    help = "visualize flow graph"
    action = :command
  "ontology"
    help = "export ontology"
    action = :command
end

@add_arg_table settings["record"] begin
  "path"
    help = "input script (Python or R file) or directory"
    required = true
  "-o", "--out"
    help = "output raw flow graph (GraphML file) or directory"
  "--graph-outputs"
    help = "whether and how to retain outputs of raw flow graph (Python only)"
    default = "none"
end

@add_arg_table settings["enrich"] begin
  "path"
    help = "input raw flow graph (GraphML file) or directory"
    required = true
  "-o", "--out"
    help = "output semantic flow graph (GraphML file) or directory"
end

@add_arg_table settings["visualize"] begin
  "path"
    help = "input flow graph (GraphML file) or directory"
    required = true
  "-o", "--out"
    help = "output file or directory"
  "-t", "--to"
    help = "Graphviz output format (default: Graphviz input only)"
  "--raw"
    help = "read input as raw flow graph (default: as semantic flow graph)"
    action = :store_true
  "--open"
    help = "open output using OS default application"
    action = :store_true
end

@add_arg_table settings["ontology"] begin
  "json"
    help = "export ontology as JSON"
    action = :command
  "rdf"
    help = "export ontology as RDF/OWL"
    action = :command
end

@add_arg_table settings["ontology"]["json"] begin
  "-o", "--out"
    help = "output file (default: stdout)"
  "--indent"
    help = "number of spaces to indent (default: compact output)"
    arg_type = Int
    default = nothing
  "--no-concepts"
    help = "exclude concepts from export"
    dest_name = "concepts"
    action = :store_false
  "--no-annotations"
    help = "exclude annotations from export"
    dest_name = "annotations"
    action = :store_false
end

@add_arg_table settings["ontology"]["rdf"] begin
  "-o", "--out"
    help = "output file (default: stdout)"
  "-t", "--to"
    help = "output format (one of: \"turtle\", \"ntriples\", \"nquads\", \"trig\")"
    default = "turtle"
  "--no-concepts"
    help = "omit concepts"
    dest_name = "concepts"
    action = :store_false
  "--no-annotations"
    help = "omit annotations"
    dest_name = "annotations"
    action = :store_false
  "--no-schema"
    help = "omit preamble defining OWL schema for concepts and annotations"
    dest_name = "schema"
    action = :store_false
  "--no-provenance"
    help = "omit interoperability with PROV Ontology (PROV-O)"
    dest_name = "provenance"
    action = :store_false
  "--no-wiring-diagrams"
    help = "omit wiring diagrams in concepts and annotations"
    dest_name = "wiring"
    action = :store_false
end

""" Map CLI input/output arguments to pairs of input/output files.
"""
function parse_io_args(input::String, output::Union{String,Nothing}, exts::Dict)
  if isdir(input)
    inexts = collect(keys(exts))
    names = filter(name -> any(endswith.(name, inexts)), readdir(input))
    inputs = [ joinpath(input, name) for name in names ]
    outdir = if output == nothing; input
      elseif isdir(output); output
      else; throw(ArgParseError(
        "Output must be directory when input is directory"))
      end
    outputs = [ map_ext(joinpath(outdir, name), exts) for name in names ]
  elseif isfile(input)
    inputs = [ input ]
    outputs = [ output == nothing ? map_ext(input, exts) : output ]
  else
    throw(ArgParseError("Input must be file or directory"))
  end
  collect(zip(inputs, outputs))
end

function map_ext(name::String, ext::Dict)
  # Don't use splitext because we allow extensions with multiple dots.
  for (inext, outext) in ext
    if endswith(name, inext)
      return string(name[1:end-length(inext)], outext)
    end
  end
  throw(ArgParseError(
    "Cannot replace extension in filename: \"$name\". Supply name explicitly."))
end

# Record
########

function record(args::Dict)
  langs = Dict(
    ".py" => :python,
    ".R" => :r,
  )
  paths = parse_io_args(args["path"], args["out"], Dict(
    ".py" => ".py.graphml",
    ".R" => ".R.graphml",
  ))
  for (inpath, outpath) in paths
    ext = last(splitext(inpath))
    lang = get(langs, ext) do
      error("Unsupported file extension: $ext")
    end
    record_file(abspath(inpath), abspath(outpath), args, Val(lang))
  end
end

function record_file(inpath::String, outpath::String, args::Dict, 
                     ::Val{lang}) where lang
  if lang == :python
    error("PyCall.jl has not been imported")
  elseif lang == :r
    error("RCall.jl has not been imported")
  else
    error("Unsupported language: $lang")
  end
end

# Enrich
########

function enrich(args::Dict)
  paths = parse_io_args(args["path"], args["out"], Dict(
    ".py.graphml" => ".graphml",
    ".R.graphml" => ".graphml",
  ))
  db = OntologyDB()
  load_concepts(db)
  for (inpath, outpath) in paths
    raw = rem_literals!(read_raw_graphml(inpath))
    semantic = to_semantic_graph(db, raw)
    write_graphml(semantic, outpath)
  end
end

# Visualize
###########

function visualize(args::Dict)
  format = args["to"] == nothing ? "dot" : args["to"]
  paths = parse_io_args(args["path"], args["out"], Dict(
    ".graphml" => ".$format",
    ".xml" => ".$format",
  ))
  for (inpath, outpath) in paths
    # Read flow graph and convert to Graphviz AST.
    graphviz = if args["raw"]
      raw_graph_to_graphviz(read_raw_graphml(inpath))
    else
      semantic_graph_to_graphviz(read_semantic_graphml(inpath))
    end

    # Pretty-print Graphviz AST to output file.
    if args["to"] == nothing
      # Default: no output format, yield Graphviz dot input.
      open(outpath, "w") do f
        Graphviz.pprint(f, graphviz)
      end
    else
      # Run Graphviz with given output format.
      open(`dot -T$format -o $outpath`, "w", stdout) do f
        Graphviz.pprint(f, graphviz)
      end
    end
    if args["open"]
      DefaultApplication.open(outpath)
    end
  end
end

function raw_graph_to_graphviz(diagram::WiringDiagram)
  to_graphviz(rem_unused_ports(diagram);
    graph_name = "raw_flow_graph",
    labels = true,
    label_attr = :xlabel,
    graph_attrs = Graphviz.Attributes(
      :fontname => "Courier",
    ),
    node_attrs = Graphviz.Attributes(
      :fontname => "Courier",
    ),
    edge_attrs = Graphviz.Attributes(
      :fontname => "Courier",
      :arrowsize => "0.5",
    )
  )
end

function semantic_graph_to_graphviz(diagram::WiringDiagram)
  to_graphviz(diagram;
    graph_name = "semantic_flow_graph",
    labels = true,
    label_attr = :xlabel,
    graph_attrs=Graphviz.Attributes(
      :fontname => "Helvetica",
    ),
    node_attrs=Graphviz.Attributes(
      :fontname => "Helvetica",
    ),
    edge_attrs=Graphviz.Attributes(
      :fontname => "Helvetica",
      :arrowsize => "0.5",
    ),
    cell_attrs=Graphviz.Attributes(
      :style => "rounded",
    )
  )
end

# Ontology
##########

function ontology_as_json(args::Dict)
  docs = AbstractDict[]
  db = OntologyDB()
  if args["concepts"]
    append!(docs, OntologyDBs.api_get(db, "/concepts"))
  end
  if args["annotations"]
    append!(docs, OntologyDBs.api_get(db, "/annotations"))
  end
  if args["out"] != nothing
    open(args["out"], "w") do out
      JSON.print(out, docs, args["indent"])
    end
  else
    JSON.print(stdout, docs, args["indent"])
  end
end

function ontology_as_rdf(args::Dict)
  # Load ontology data from remote database.
  db = OntologyDB()
  if args["concepts"]
    load_concepts(db)
  end
  if args["annotations"]
    load_annotations(db)
  end

  # Load ontology schemas from filesystem.
  stmts = Serd.RDF.Statement[]
  if args["schema"]
    append!(stmts, [
      read_ontology_rdf_schema("list.ttl");
      args["concepts"] ? read_ontology_rdf_schema("concept.ttl") : [];
      args["annotations"] ? read_ontology_rdf_schema("annotation.ttl") : [];
      args["wiring"] ? read_ontology_rdf_schema("wiring.ttl") : [];
    ])
  end

  # Convert to RDF.
  prefix = Serd.RDF.Prefix("dso", "https://www.datascienceontology.org/ns/dso/")
  append!(stmts, ontology_to_rdf(db, prefix,
    include_provenance=args["provenance"],
    include_wiring_diagrams=args["wiring"]))

  # Serialize RDF to file or stdout.
  syntax = args["to"]
  if args["out"] != nothing
    open(args["out"], "w") do out
      Serd.write_rdf(out, stmts, syntax=syntax)
    end
  else
    Serd.write_rdf(stdout, stmts, syntax=syntax)
  end
end

function read_ontology_rdf_schema(name::String)
  Serd.read_rdf_file(joinpath(ontology_rdf_schema_dir, name))
end

const ontology_rdf_schema_dir = joinpath(@__DIR__, "ontology", "rdf", "schema")

# CLI main
##########

function main(args)
  invoke(parse(args)...)
end

function parse(args)
  cmds = String[]
  parsed_args = parse_args(args, settings)
  while haskey(parsed_args, "%COMMAND%")
    cmd = parsed_args["%COMMAND%"]
    parsed_args = parsed_args[cmd]
    push!(cmds, cmd)
  end
  return (cmds, parsed_args)
end

function invoke(cmds, cmd_args)
  try
    cmd_fun = command_table
    for cmd in cmds; cmd_fun = cmd_fun[cmd] end
    cmd_fun(cmd_args)
  catch err
    # Handle further "parsing" errors ala ArgParse.jl.
    isa(err, ArgParseError) || rethrow()
    settings.exc_handler(settings, err)
  end
end

const command_table = Dict(
  "record" => record,
  "enrich" => enrich,
  "visualize" => visualize,
  "ontology" => Dict(
    "json" => ontology_as_json,
    "rdf" => ontology_as_rdf,
  ),
)

# CLI extras
############

function __init__()
  @require PyCall="438e738f-606a-5dbb-bf0a-cddfbfd45ab0" include("extras/CLI-Python.jl")
  @require RCall="6f49c342-dc21-5d91-9882-a32aef131414" include("extras/CLI-R.jl")
end

end
