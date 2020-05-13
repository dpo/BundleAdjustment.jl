using SparseArrays
using SolverTools
using NLPModels
using AMD
using Metis
include("lma_aux.jl")
include("ldl_aux.jl")
include("qr_aux.jl")



"""
Implementation of Levenberg Marquardt algorithm for NLSModels
Solves min 1/2 ||r(x)||² where r is a vector of residuals
"""
function Levenberg_Marquardt(model :: AbstractNLSModel,
							 facto :: Symbol,
							 perm :: Symbol;
							 x :: AbstractVector=copy(model.meta.x0),
							 restol=100*sqrt(eps(eltype(x))),
							 satol=sqrt(eps(eltype(x))), srtol=sqrt(eps(eltype(x))),
							 otol=100*sqrt(eps(eltype(x))),
							 atol=100*sqrt(eps(eltype(x))), rtol=100*sqrt(eps(eltype(x))),
							 νd :: Real=3.0, νm :: Real=3.0, λ :: Real=1.5,
							 ite_max :: Int=500)

  start_time = time()
  elapsed_time = 0.0
  iter = 0
  step_accepted = ""
  δ = 0
  T = eltype(x)
  νd = convert(T, νd)
  νm = convert(T, νm)
  λ = convert(T, λ)
  x_suiv = Vector{T}(undef, length(x))


  # Initialize residuals
  r = residual(model, x)
  sq_norm_r = norm(r)^2
  sq_norm_r₀ = sq_norm_r
  r_suiv = copy(r)
  # Initialize b = [r; 0]
  b = [-r; zeros(T, model.meta.nvar)]
  xr = similar(b)

  # Initialize J in the format J[rows[k], cols[k]] = vals[k]
  rows = Vector{Int}(undef, model.nls_meta.nnzj)
  cols = Vector{Int}(undef, model.nls_meta.nnzj)
  jac_structure_residual!(model, rows, cols)
  vals = jac_coord_residual(model, x)

  # Nearly zero or nearly linear residuals
  resatol = 100 * restol
  resrtol = 100 * restol
  snd_order = false
  counter_res_null = 0
  Jδ = Vector{T}(undef, model.nls_meta.nequ)
  Jδ_suiv = similar(Jδ)
  jtol = restol

  if facto == :QR
	  # Initialize A = [J; √λI] as a sparse matrix
	  A = sparse(vcat(rows,collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(cols, collect(1 : model.meta.nvar)), vcat(vals, fill(sqrt(λ), model.meta.nvar)), model.nls_meta.nequ + model.meta.nvar, model.meta.nvar)
	  # col_norms = Vector{T}(undef, model.meta.nvar)

	  # Givens version
	  # col_norms = ones(model.meta.nvar)
	  # col_norms = Vector{T}(undef, model.meta.nvar)
	  # normalize_cols!(A[1 : model.nls_meta.nequ, :], col_norms, model.meta.nvar)
	  # QR_J = qr(A[1 : model.nls_meta.nequ, :])
	  # G_list = Vector{LinearAlgebra.Givens{Float64}}(undef, Int(model.meta.nvar*(model.meta.nvar + 1)/2))
	  # news = Vector{Float64}(undef, model.meta.nvar)
	  # Prow = vcat(QR_J.prow, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar))
	  # denormalize_cols!(A[1 : model.nls_meta.nequ, :], col_norms, model.meta.nvar)

	  Jtr = transpose(A[1 : model.nls_meta.nequ, :])*r

  elseif facto == :LDL
	  # Initialize A = [[I J]; [Jᵀ - λI]] as sparse upper-triangular matrix
	  cols_J = copy(cols)
	  cols .+= model.nls_meta.nequ
	  A = sparse(vcat(collect(1 : model.nls_meta.nequ), rows, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(collect(1 : model.nls_meta.nequ), cols, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(fill(1.0, model.nls_meta.nequ), vals, fill(-λ, model.meta.nvar)))
	  # col_norms = Vector{T}(undef, model.meta.nvar + model.nls_meta.nequ)
	  if perm == :AMD
		  P = amd(A)
	  elseif perm == :Metis
		  P , _ = Metis.permutation(A' + A)
	  	  P = convert(Array{Int64,1}, P)
	  end
	  ldl_symbolic = ldl_analyse(A, P, upper=true, n=model.meta.nvar + model.nls_meta.nequ)
	  Jtr = transpose(A[1 : model.nls_meta.nequ, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar])*r
  end

  ϵ_first_order = atol + rtol * norm(Jtr)
  old_obj = sq_norm_r / 2

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

	@info log_row([iter, sq_norm_r / 2, old_obj - sq_norm_r / 2, norm(δ), step_accepted])

	# If the residuals are nearly zeros 5 times in a row, we use 2nd order derivatives
	# if sq_norm_r > resatol + resrtol * sq_norm_r₀
	# 	counter_res_null += 1
	# else
	# 	counter_res_null = 0
	# end
	# if counter_res_null > 5
	# 	snd_order = true
	# end


	if facto == :QR
	    # Solve min ||[J √λI] δ + [r 0]||² with QR factorization

		# Givens version
		# counter = fullQR_givens!(QR_J.R, G_list, news, sqrt(λ), col_norms, model.meta.nvar, model.nls_meta.nequ)
		# print("\n", counter)
		# δ, δr = solve_qr2!(model.nls_meta.nequ + model.meta.nvar, model.meta.nvar, xr, b, QR_J.Q, QR_J.R, Prow, QR_J.pcol, counter, G_list)
		# denormalize!(δ, col_norms, model.meta.nvar)
		# denormalize!(δr, col_norms, model.meta.nvar)

		# Original version
		# normalize_cols!(A, col_norms, model.meta.nvar)
		if perm == :AMD
			QR = myqr(A, ordering=SuiteSparse.SPQR.ORDERING_AMD)
		elseif perm == :Metis
			QR = myqr(A, ordering=SuiteSparse.SPQR.ORDERING_METIS)
		end
		δ, δr = solve_qr!(model.nls_meta.nequ + model.meta.nvar, model.meta.nvar, xr, b, QR.Q, QR.R, QR.prow, QR.pcol)
		# denormalize!(δ, col_norms, model.meta.nvar)
		# denormalize!(δr, col_norms, model.meta.nvar)

	elseif facto == :LDL
		# Solve [[I J]; [Jᵀ - λI]] X = [-r; 0] with LDL factorization
		# normalize_cols!(A, col_norms, model.meta.nvar + model.nls_meta.nequ)
		LDLT = ldl_factorize(A, ldl_symbolic, true)
		xr .= b
		ldl_solve!(model.nls_meta.nequ + model.meta.nvar, xr, LDLT.L.colptr, LDLT.L.rowval, LDLT.L.nzval, LDLT.D, P)
		# denormalize!(xr, col_norms, model.nls_meta.nequ + model.meta.nvar)
		δr = xr[1 : model.nls_meta.nequ]
		δ = xr[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar]
	end

	x_suiv .=  x + δ
	residual!(model, x_suiv, r_suiv)
	iter += 1
	# print("\n", norm(Jtr))

    # Step not accepted : d(||r||²) > 1e-4 (||Jδ + r||² - ||r||²)
    if norm(r_suiv)^2 - sq_norm_r >= 1e-4 * (norm(δr)^2 - sq_norm_r)
	  step_accepted = "false"
      # Update λ
      λ *= νm

	  # Update A
	  if facto == :QR
		  # Original version
		  # denormalize_cols!(A, col_norms, model.meta.nvar)

		  A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, :] *= sqrt(νm)

	  elseif facto == :LDL
		  # denormalize_cols!(A, col_norms, model.meta.nvar + model.nls_meta.nequ)
		  A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar] *= νm
	  end

    # Step accepted
    else
	  step_accepted = "true"

      # Update λ and x
      λ /= νd
      x .= x_suiv

	  # Update J and check if the jacobian is constant
	  if facto == :QR
	  	# mul_sparse!(Jδ, rows, cols, vals, δ, model.nls_meta.nnzj)
		jac_coord_residual!(model, x, vals)
  	  	# if jac_not_const(Jδ, Jδ_suiv, rows, cols, vals, δ, model.nls_meta.nnzj, jtol)
  	    #   snd_order = true
    	# end
	  elseif facto == :LDL
		# mul_sparse!(Jδ, rows, cols_J, vals, δ, model.nls_meta.nnzj)
		jac_coord_residual!(model, x, vals)
  	  	# if jac_not_const(Jδ, Jδ_suiv, rows, cols_J, vals, δ, model.nls_meta.nnzj, jtol)
  	    #   snd_order = true
    	# end
	  end

	  # Update r and b
	  old_obj = sq_norm_r / 2
      r .= r_suiv
	  b[1 : model.nls_meta.nequ] .= -r
      sq_norm_r = norm(r)^2


	  # Update A and Jtr
	  if facto == :QR
		  A = sparse(vcat(rows,collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(cols, collect(1 : model.meta.nvar)), vcat(vals, fill(sqrt(λ), model.meta.nvar)), model.nls_meta.nequ + model.meta.nvar, model.meta.nvar)

		  # Givens version
		  # normalize_cols!(A[1 : model.nls_meta.nequ, :], col_norms, model.meta.nvar)
		  # QR_J = qr(A[1 : model.nls_meta.nequ, :])
		  # denormalize_cols!(A[1 : model.nls_meta.nequ, :], col_norms, model.meta.nvar)

	      mul!(Jtr, transpose(A[1 : model.nls_meta.nequ, :] ), r)

	  elseif facto == :LDL
		  A = sparse(vcat(collect(1 : model.nls_meta.nequ), rows, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(collect(1 : model.nls_meta.nequ), cols, collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(fill(1.0, model.nls_meta.nequ), vals, fill(-λ, model.meta.nvar)))
		  mul!(Jtr, transpose(A[1 : model.nls_meta.nequ, model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar]), r)
	  end

	  # Update the stopping criteria
	  small_step = norm(δ) < satol + srtol * norm(x)
      first_order = norm(Jtr) < ϵ_first_order
      small_residual = norm(r) < restol
      small_obj_change =  old_obj - sq_norm_r / 2 < otol * old_obj
    end

	tired = iter > ite_max
  end

  @info log_row(Any[iter, sq_norm_r / 2, old_obj - sq_norm_r / 2, norm(δ), step_accepted])

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

  return GenericExecutionStats(status, model, solution=x, objective=sq_norm_r/2, iter=iter, elapsed_time=elapsed_time, primal_feas=norm(Jtr))
end
