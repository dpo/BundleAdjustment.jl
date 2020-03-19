using NLPModels
using LinearAlgebra
import NLPModels: increment!
include("ReadFiles.jl")
include("JacobianByHand.jl")


function scaling_factor(point, k1, k2)
    sq_norm_point = dot(point, point)
    return 1.0 + k1*sq_norm_point + k2*sq_norm_point^2
end


function projection!(p3, r, t, f, k1, k2, r2)
  θ = norm(r)
  k = r / θ
  P1 = cos(θ) * p3 + sin(θ) * cross(k, p3) + (1 - cos(θ)) * dot(k, p3) * k + t
  P2 = -P1[1:2] / P1[3]
  r2[:] = f * scaling_factor(P2, k1, k2) * P2
  return r2
end


projection!(x, c, r2) = projection!(x, c[1:3], c[4:6], c[7], c[8], c[9], r2)


function residuals!(cam_indices, pnt_indices, xs, r)
  nobs = length(cam_indices)
  for k = 1 : nobs
    cam_index = cam_indices[k]
    pnt_index = pnt_indices[k]
    # x = xs[(pnt_index - 1) * 12 + 1 : pnt_index * 12]
    x = xs[(pnt_index - 1) * 3 + 1 : (pnt_index - 1) * 3 + 3]
    c = xs[3*npts + (cam_index - 1) * 9 + 1 : 3*npts + (cam_index - 1) * 9 + 9]
    projection!(x, c, r[2 * k - 1 : 2 * k])
  end
  return r
end


"""
Represent a bundle adjustement problem in the form

    minimize    0
    subject to  F(x) = 0,

where `F(x)` is the vector of residuals.
"""
mutable struct BALNLPModel <: AbstractNLPModel
  meta :: NLPModelMeta
  counters :: Counters
  cams_indices
  pnts_indices
  pt2d
  cam_params
  pt3d
end


function BALNLPModel(filename::AbstractString)
  cams_indices, pnts_indices, pt2d, cam_params, pt3d = readfile(filename)

  # variables: 9 parameters per camera + 3 coords per 3d point
  ncams = size(cam_params, 1)
  npnts = size(pt3d, 1)
  nvar = 9 * ncams + 3 * npnts

  # number of residuals: two residuals per 2d point
  nobs = size(pt2d, 1)
  ncon = 2 * nobs

  x0 = Vector{Float64}(undef, nvar)
  for k = 1 : nobs
    cam_index = cams_indices[k]
    pnt_index = pnts_indices[k]
    x0[(pnt_index - 1) * 3 + 1 : (pnt_index - 1) * 3 + 3] = pt3d[pnt_index, :]
    x0[3*npnts + (cam_index - 1) * 9 + 1 : 3*npnts + (cam_index - 1) * 9 + 9] = cam_params[cam_index, :]
  end

  meta = NLPModelMeta(nvar, ncon=ncon, x0=x0, nnzj=2*nobs*12, name="filename")

  @info "BALNLPModel $filename" nvar ncon
  return BALNLPModel(meta, Counters(), cams_indices, pnts_indices, pt2d, cam_params, pt3d)
end


obj(model::BALNLPModel, x) = 0.0


grad!(model::BALNLPModel, x, g) = fill!(g, 0)


function cons!(nlp :: BALNLPModel, x :: AbstractVector, cx :: AbstractVector)
  increment!(nlp, :neval_cons)
  residuals!(nlp.cams_indices, nlp.pnts_indices, x, cx)
  cx .-= nlp.pt2d'[:] # flatten pt2d so it has size 2 * nobs
  return cx
end

function jac_structure!(nlp :: BALNLPModel, rows :: AbstractVector, cols :: AbstractVector)
  increment!(nlp, :neval_jac)
  nobs = size(nlp.pt2d)[1]
  npnts = size(nlp.pt3d)[1]
  for k = 1 : nobs
    idx_cam = nlp.cams_indices[k]
    idx_pnt = nlp.pnts_indices[k]

    # Only the two rows corresponding to the observation k are not empty
    # And there are 12 per row
    rows[(k-1)*24 + 1 : (k-1)*24 + 12] = fill(2*k - 1, 12)
    rows[(k-1)*24 + 13 : (k-1)*24 + 24] = fill(2*k, 12)

    # 3 columns for the 3D point observed
    cols[(k-1)*24 + 1 : (k-1)*24 + 3] = 3*(idx_pnt - 1) + 1: 3*(idx_pnt - 1) + 3
    cols[(k-1)*24 + 13 : (k-1)*24 + 15] = 3*(idx_pnt - 1) + 1: 3*(idx_pnt - 1) + 3

    # 9 columns for the camera
    cols[(k-1)*24 + 4 : (k-1)*24 + 12] = 3*npnts + 9*(idx_cam - 1) + 1 : 3*npnts + 9*(idx_cam - 1) + 9
    cols[(k-1)*24 + 16 : (k-1)*24 + 24] = 3*npnts + 9*(idx_cam - 1) + 1 : 3*npnts + 9*(idx_cam - 1) + 9
  end
end


function jac_coord!(nlp :: BALNLPModel, x :: AbstractVector, vals :: AbstractVector)
  increment!(nlp, :neval_jac)
  nobs = size(nlp.pt2d)[1]
  npnts = size(nlp.pt3d)[1]
  for k = 1 : nobs
    idx_cam = nlp.cams_indices[k]
    idx_pnt = nlp.pnts_indices[k]
    X = x[(idx_pnt - 1) * 3 + 1 : (idx_pnt - 1) * 3 + 3] # 3D point coordinates
    C = x[3*npnts + (idx_cam - 1) * 9 + 1 : 3*npnts + (idx_cam - 1) * 9 + 9] # camera parameters
    r = C[1:3]  # Rodrigues vector for the rotation
    t = C[4:6]  # translation vector
    f, k1, k2 = C[7:9]  # focal length and radial distortion factors
    denseJ = JP3(P2(P1(r, t, X)), f, k1, k2)*JP2(P1(r, t, X))*JP1(r, X)

    # Feel vals with the values of denseJ = [[∂P.x/∂X ∂P.x/∂C], [∂P.y/∂X ∂P.y/∂C]]
    vals[(k-1)*24 + 1 : (k-1)*24 + 3] = denseJ[1, 1:3]
    vals[(k-1)*24 + 13 : (k-1)*24 + 15] = denseJ[2, 1:3]
    vals[(k-1)*24 + 4 : (k-1)*24 + 12] = denseJ[1, 4:12]
    vals[(k-1)*24 + 16 : (k-1)*24 + 24] = denseJ[2, 4:12]
  end
  return vals
end
