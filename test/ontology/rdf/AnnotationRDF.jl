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

module TestAnnotationRDF
using Test

using Serd, Serd.RDF
using Catlab

using SemanticFlowGraphs

const R = Resource

A, B, C, D = Ob(Monocl, "A", "B", "C", "D")
f = Hom("f", A, B)
g = Hom("g", B, C)
h = Hom("h", D, D)

# Object annotations

prefix = RDF.Prefix("ex", "http://www.example.org/#")
annotation = ObAnnotation(
  AnnotationID("python", "mypkg", "a"),
  Dict(
    :class => "ClassA",
    :slots => [Dict("slot" => "attrB")],
  ),
  A, [f]
)
stmts = annotation_to_rdf(annotation, prefix)
node = R("ex", "python:mypkg:a")
@test Triple(node, R("monocl", "annotatedLanguage"), Literal("python")) in stmts
@test Triple(node, R("monocl", "annotatedPackage"), Literal("mypkg")) in stmts
@test Triple(node, R("monocl", "annotatedClass"), Literal("ClassA")) in stmts
@test Triple(node, R("monocl", "codeDefinition"), R("ex","A")) in stmts

slot_node = R("ex", "python:mypkg:a:slot1")
@test Triple(node, R("monocl", "annotatedSlot"), slot_node) in stmts
@test Triple(slot_node, R("monocl", "codeDefinition"), R("ex","f")) in stmts
@test Triple(slot_node, R("monocl", "codeSlot"), Literal("attrB")) in stmts

# Morphism annotations

annotation = HomAnnotation(
  AnnotationID("python", "mypkg", "a-do-composition"),
  Dict(
    :class => ["ClassA", "MixinB"],
    :method => "do_composition",
    :inputs => [Dict("slot" => 1)],
    :outputs => [Dict("slot" => "return")],
  ),
  compose(f,g)
)
node = R("ex", "python:mypkg:a-do-composition")
root_node = R("ex", "python:mypkg:a-do-composition:diagram:root")
stmts = annotation_to_rdf(annotation, prefix)
@test Triple(node, R("monocl", "annotatedLanguage"), Literal("python")) in stmts
@test Triple(node, R("monocl", "annotatedPackage"), Literal("mypkg")) in stmts
@test Triple(node, R("monocl", "annotatedClass"), Literal("ClassA")) in stmts
@test Triple(node, R("monocl", "annotatedClass"), Literal("MixinB")) in stmts
@test Triple(node, R("monocl", "annotatedMethod"), Literal("do_composition")) in stmts
@test Triple(node, R("monocl", "codeDefinition"), root_node) in stmts

end
