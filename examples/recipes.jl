using Flux, MLDataPattern, Mill, JsonGrinder, JSON, IterTools, Statistics, BenchmarkTools, ThreadTools
import JsonGrinder: suggestextractor, ExtractCategorical, ExtractDict, ExtractString, MultipleRepresentation, extractscalar
import Mill: mapdata, sparsify, reflectinmodel

###############################################################
# start by loading all samples
###############################################################
samples = open("examples/recipes.json","r") do fid
	Vector{Dict}(JSON.parse(read(fid, String)))
end
JSON.print(samples[1],2)


###############################################################
# create schema of the JSON
###############################################################
sch = JsonGrinder.schema(samples)

###############################################################
# create extractor and split it into one for loading targets and
# one for loading data, using custom function to set conditions for using n-gram representation
###############################################################
delete!(sch.childs,:id)

limituse(d::Dict{T,Int}, limit) where {T} = collect(filter(k -> d[k] >= limit, keys(d)))

function custom_scalar_extractor()
	[(e -> promote_type(unique(typeof.(keys(e.counts)))...) <: String,
		e -> MultipleRepresentation((ExtractCategorical(limituse(e.counts, 10)), ExtractString(String)))),
	 (e -> (length(keys(e.counts)) / e.updated < 0.1  && length(keys(e.counts)) <= 10000),
		e -> ExtractCategorical(collect(keys(e.counts)))),
	 (e -> true,
		e -> extractscalar(promote_type(unique(typeof.(keys(e.counts)))...))),]
end

extractor = suggestextractor(sch, (scalar_extractors=custom_scalar_extractor(), mincount=100,))

extract_data = ExtractDict(nothing,deepcopy(extractor.other))
extract_target = ExtractDict(nothing,deepcopy(extractor.other))
delete!(extract_target.other, :ingredients)
delete!(extract_data.other, :cuisine)
extract_target.other[:cuisine] = JsonGrinder.ExtractCategorical(keys(sch[:cuisine]))

extract_data(JsonGrinder.sample_synthetic(sch))
###############################################################
# we convert JSONs to Datasets
###############################################################
# advised to use all the samples, this is just speedup to demonstrate functionality
data = tmap(extract_data, samples[1:5_000])
data = reduce(catobs, data)
target = tmap(extract_target, samples[1:5_000])
# replace by this once we'll merge the correct handling of dicts
#target = reduce(catobs, target)[:cuisine].data
target = reduce(catobs, target).data

e = sch[:cuisine]

###############################################################
# 	create the model according to the data
###############################################################
m = reflectinmodel(sch, extract_data,
	k -> Dense(k,20,relu),
	d -> SegmentedMeanMax(d),
	b = Dict("" => k -> Dense(k, size(target, 1))),
)

###############################################################
#  train
###############################################################
opt = Flux.Optimise.ADAM()
loss = (x,y) -> Flux.logitcrossentropy(m(x).data, y)
valdata = data[1:1_000],target[:,1:1_000]
data, target = data[1_001:5_000], target[:,1001:5_000]
# for less recourse-chungry training, we use only part of data for trainng, but it is advised to used all, as i following line:
# data, target = data[1001:nobs(data)], target[:,1001:size(target,2)]

cb = () -> println("accuracy = ",mean(Flux.onecold(m(valdata[1]).data) .== Flux.onecold(valdata[2])))
batch_size = 100
#iterations = 1000
iterations = 100
ps = Flux.params(m)
mean(Flux.onecold(m(data).data) .== Flux.onecold(target))

@info "testing the gradient"
gs = gradient(() -> loss(data, target), ps)
Flux.Optimise.update!(opt, ps, gs)

Flux.Optimise.train!(loss, ps, repeatedly(() -> (data, target), 20), opt, cb = Flux.throttle(cb, 2))
# feel free to train for longer period of time, this example is learns only 20 iterations, so it runs fast
# Flux.Optimise.train!(loss, ps, repeatedly(() -> (data, target), 500), opt, cb = Flux.throttle(cb, 10))

#calculate the accuracy
mean(Flux.onecold(m(data).data) .== Flux.onecold(target))

# samples = open("recipes_test.json","r") do fid
# 	Array{Dict}(JSON.parse(readstring(fid)))
# end
# ids = map(s -> s["id"],samples)
# tstdata = @>> samples map(extract_data);
# tstdata = cat(tstdata...);
# tstdata = mapdata(sentence2ngrams,tstdata)
# tstdata = mapdata(i -> sparsify(Float32.(i),0.05),tstdata)
# names = extract_target.other["cuisine"].items
# y = map(i -> names[i],Flux.argmax(m(tstdata)));


# using DataFrames
# CSV.write("cuisine.csv",DataFrame(id = ids,cuisine = y ),delim=',')

# schema can also be created in parallel for better performance, compare:

# single threaded
# @btime JsonGrinder.schema(samples)
# multi threaded
# @btime merge(tmap(x->JsonGrinder.schema(collect(x)), Iterators.partition(samples, 5_000))...)
