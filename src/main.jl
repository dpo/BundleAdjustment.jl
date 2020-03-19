include("ReadFiles.jl")
include("ModelJuMP.jl")
include("ModelNLP.jl")

#
# # Get cameras indices, point indices, points 2D, cameras and points 3D matrices for datasets
# cam_indices, pnt_indices, pt2d, cam_params, pt3d = readfile("LadyBug/problem-49-7776-pre.txt.bz2")
#
# # Find optimal camera features and points
# cameras_opt, points_opt = direct_model(cam_indices, pnt_indices, pt2d, cam_params, pt3d)
# cameras_opt, points_opt = residual_model(cam_indices, pnt_indices, pt2d, cam_params, pt3d)
#
# # Save them into a  file
# writedlm("Cameras.txt", cameras_opt)
# writedlm("Points.txt", points_opt)

BA49 = BALNLPModel("LadyBug/problem-49-7776-pre.txt.bz2")

rows = Vector{Int}(undef, BA49.meta.nnzj)
cols = Vector{Int}(undef, BA49.meta.nnzj)
jac_structure!(BA49, rows, cols)

vals = Vector{Float64}(undef, BA49.meta.nnzj)
vals = jac_coord!(BA49, BA49.meta.x0, vals)

using SparseArrays
J = sparse(rows, cols, vals)
print(J)

# err = jacobian_check(BA49, x=BA49.meta.x0)
