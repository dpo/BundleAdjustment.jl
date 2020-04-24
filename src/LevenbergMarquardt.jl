using SparseArrays
using SolverTools
using NLPModels
using AMD
using Metis
include("LMA_aux.jl")



"""
Implementation of Levenberg Marquardt algorithm for NLSModels
Solves min 1/2 ||r(x)||² where r is a vector of residuals
"""
function Levenberg_Marquardt(model :: AbstractNLSModel,
							 facto :: Symbol,
							 perm :: Symbol,
							 x :: AbstractVector=copy(model.meta.x0),
							 restol :: Float64=1e-5,
							 satol :: Float64=1e-5, srtol :: Float64=1e-5,
							 otol :: Float64=1e-4,
							 atol :: Float64=1e-5, rtol :: Float64=1e-5,
							 νd :: Float64=3.0, νm :: Float64=3.0, λ :: Float64=1.5,
							 ite_max :: Int=100)

  start_time = time()
  elapsed_time = 0.0
  iter = 0
  step_accepted = ""
  δ = 0
  T = eltype(x)
  x_suiv = Vector{T}(undef, length(x))

  # Initialize residuals
  r = residual(model, x)
  sq_norm_r = norm(r)^2
  r_suiv = copy(r)

  # Initialize J in the format J[rows[k], cols[k]] = vals[k]
  rows = Vector{Int}(undef, model.nls_meta.nnzj)
  cols = Vector{Int}(undef, model.nls_meta.nnzj)
  jac_structure_residual!(model, rows, cols)
  vals = jac_coord_residual(model, x)


  if facto == :QR

	  # Initialize b = [r; 0]
	  b = [r; zeros(model.meta.nvar)]
	  xr = similar(b)

	  # Initialize A = [J; √λI] as a sparse matrix
	  A = sparse(vcat(rows,collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(cols, collect(1 : model.meta.nvar)), vcat(vals, fill(sqrt(λ), model.meta.nvar)), model.nls_meta.nequ + model.meta.nvar, model.meta.nvar)
	  QR_J = qr(A[1 : model.nls_meta.nequ, :])

	  Jtr = transpose(A[1 : model.nls_meta.nequ, :])*r

  elseif facto == :LDL

	  # Initialize b = [-r; 0]
	  b = [-r; zeros(model.meta.nvar)]
	  xr = similar(b)

	  # Initialize A = [[I J]; [Jᵀ - λI]] as sparse upper-triangular matrix
	  cols .+= model.nls_meta.nequ
	  A = sparse(vcat(collect(1 : model.nls_meta.nequ), rows, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(collect(1 : model.nls_meta.nequ), cols, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(fill(1.0, model.nls_meta.nequ), vals, fill(-λ, model.meta.nvar)))
	  if perm == :AMD
		  P = amd(A)
	  elseif perm == :Metis
		  P , _ = Metis.permutation(A' + A)
	  	  P = convert(Array{Int64,1}, P)
	  end

	  Jtr = transpose(A[1 : model.nls_meta.nequ, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar])*r
  end

  ϵ_first_order = atol + rtol * norm(Jtr)
  old_obj = 0.5 * sq_norm_r

  # Stopping criteria
  small_step = false
  first_order = norm(Jtr) < ϵ_first_order
  small_residual = norm(r) < restol
  small_obj_change =  false
  tired = iter > ite_max
  status = :unknown

  @info log_header([:iter, :f, :dual, :step, :bk], [Int, T, T, T, String],
  hdr_override=Dict(:f=>"½‖r‖² ", :dual=>" d(½‖r‖²)", :step=>"‖δ‖  ", :bk=>"step accepted"))

  while !(small_step || first_order || small_residual || small_obj_change || tired)

	@info log_row([iter, 0.5 * sq_norm_r, old_obj - 0.5 * sq_norm_r, norm(δ), step_accepted])

	if facto == :QR
	    # Solve min ||[J √λI] δ + [r 0]||² with QR factorization
		# Q, R = fullQR_Givens!(QR_J.Q, QR_J.R, λ, model.nls_meta.nequ, model.meta.nvar)
		# δ, δr = solve_qr!(model.nls_meta.nequ + model.meta.nvar, model.meta.nvar, xr, b, Q, R, QR_J.prow, QR_J.pcol)
		if perm == :AMD
			QR = myqr(A, ordering=SuiteSparse.SPQR.ORDERING_AMD)
		elseif perm == :Metis
			QR = myqr(A, ordering=SuiteSparse.SPQR.ORDERING_METIS)
		end

		δ, δr = solve_qr!(model.nls_meta.nequ + model.meta.nvar, model.meta.nvar, xr, b, QR.Q, QR.R, QR.prow, QR.pcol)
	    x_suiv .=  x - δ

	elseif facto == :LDL
		# Solve [[I J]; [Jᵀ - λI]] X = [r; 0] with LDL factorization
		LDLT = ldl(A, P, upper=true)
		xr .= b
		ldl_solve!(model.nls_meta.nequ + model.meta.nvar, xr, LDLT.L.colptr, LDLT.L.rowval, LDLT.L.nzval, LDLT.D, P)
		δr = xr[1 : model.nls_meta.nequ]
		δ = xr[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar]
		x_suiv .=  x + δ
	end

	residual!(model, x_suiv, r_suiv)
	iter += 1

    # Step not accepted : d(||r||²) > 1e-4 (||Jδ + r||² - ||r||²)
    if norm(r_suiv)^2 - sq_norm_r >= 1e-4 * (norm(δr)^2 - sq_norm_r)
	  step_accepted = "false"
      # Update λ
      λ *= νm

	  # Update A
	  if facto == :QR
		  A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, :] *= sqrt(νm)
	  elseif facto == :LDL
		  A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar] *= νm
	  end

    #Step accepted
    else
	  step_accepted = "true"

      # Update λ and x
      λ /= νd
      x .= x_suiv

	  # Update J and r
	  jac_coord_residual!(model, x, vals)
	  old_obj = 0.5*sq_norm_r
      r .= r_suiv
      sq_norm_r = norm(r)^2

	  # Update A, b and Jtr
	  if facto == :QR
		  A = sparse(vcat(rows,collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(cols, collect(1 : model.meta.nvar)), vcat(vals, fill(sqrt(λ), model.meta.nvar)), model.nls_meta.nequ + model.meta.nvar, model.meta.nvar)
		  # QR_J = qr(A[1 : model.nls_meta.nequ, :])
		  b[1 : model.nls_meta.nequ] .= r
	      mul!(Jtr, transpose(A[1 : model.nls_meta.nequ, :] ), r)

	  elseif facto == :LDL
		  A = sparse(vcat(collect(1 : model.nls_meta.nequ), rows, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(collect(1 : model.nls_meta.nequ), cols, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(fill(1.0, model.nls_meta.nequ), vals, fill(-λ, model.meta.nvar)))
		  b[1 : model.nls_meta.nequ] .= -r
		  mul!(Jtr, transpose(A[1 : model.nls_meta.nequ, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar]), r)
	  end

	  # Update the stopping criteria
	  small_step = norm(δ) < satol + srtol * norm(x)
      first_order = norm(Jtr) < ϵ_first_order
      small_residual = norm(r) < restol
      small_obj_change =  old_obj - 0.5 * sq_norm_r < otol * old_obj
      tired = iter > ite_max
    end
  end

  @info log_row(Any[iter, 0.5 * sq_norm_r, old_obj - 0.5 * sq_norm_r, norm(δ), step_accepted])

  if small_step
	  status = :small_step
  elseif first_order
	  status = :first_order
  elseif small_residual
	  status = :small_residual
  elseif small_obj_change
	  status = :acceptable
  else
	  status = :max_iter
  end

  elapsed_time = time() - start_time

  return GenericExecutionStats(status, model, solution=x, objective=0.5*sq_norm_r, iter=iter, elapsed_time=elapsed_time, primal_feas=norm(Jtr))
end
