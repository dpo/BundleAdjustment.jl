using LinearAlgebra


"""
Implementation of Levenberg Marquardt algorithm for NLSModels
"""
function Levenberg_Marquardt(model::AbstractNLSModel, x0::Array{Float64,1}, atol::Float64, rtol::Float64, ite_max::Int)
  lambda = 1.5 # regularization coefficient
  x = x0
  x_suiv = Vector{Float64}(undef, length(x))
  ite = 0

  # Initialize residuals
  print("\n r")
  r = @time residual(model, x0)
  sq_norm_r = norm(r)^2
  r_suiv = copy(r)
  # Initialize b = [r; 0]
  b = [r; zeros(model.meta.nvar)]

  # Initialize J in the format J[rows[k], cols[k]] = vals[k]
  print("\n J")
  rows = Vector{Int}(undef, model.nls_meta.nnzj)
  cols = Vector{Int}(undef, model.nls_meta.nnzj)
  @time jac_structure_residual!(model, rows, cols)
  @time vals = jac_coord_residual(model, x)

  # Initialize A = [J; √λI] as a sparse matrix
  print("\n A")
  @time A = sparse(vcat(rows,collect(model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar)), vcat(cols, collect(1 : model.meta.nvar)), vcat(vals, fill(sqrt(lambda), model.meta.nvar)), model.nls_meta.nequ + model.meta.nvar, model.meta.nvar)
  # print("\n", A.nzval[1:24], "\n", A.nzval[764220:764240])

  # The stopping criteria is: stop = norm(Jᵀr) > stop_inf = atol + rtol*stop(0)
  Jtr = transpose(A[1 : model.nls_meta.nequ, :])*r
  stop = norm(Jtr)
  stop_inf = atol + rtol*stop
  while  stop > stop_inf && ite < ite_max
    print("\nIteration: ", ite, ", Objective: ", 0.5*sq_norm_r,  ", Stopping criteria: ", stop_inf, " ", stop, "\n")

    # Solve min ||[J √λI] δ + [r 0]||² with QR factorization
    print("\ndelta ")
    @time delta = A \ b
    @time x_suiv .=  x - delta
    @time residual!(model, x_suiv, r_suiv)

    # Step not accepted
    if norm(r_suiv)^2 - sq_norm_r >= 1e-4 * (norm(A[1 : model.nls_meta.nequ, :]*delta + r)^2 - sq_norm_r)
      print("\n/!\\ step not accepted /!\\ \n")
      # Update λ and A
      lambda *= 2
      A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, :] *= sqrt(3)

    #Step accepted
    else
      # Update λ and x
      lambda /= 5
      @time x .= x_suiv
      # Update A
      print("\njac ")
      @time jac_coord_residual!(model, x, vals)
      print("\nfill ")
      # print("\n", A.nzval[1:24], "\n", A.nzval[764220:764240])
      # jac_coord_residual!(model, x, A.nzval)
      # print("\n", A.nzval[1:24], "\n", A.nzval[764220:764240])
      @time A[1 : model.nls_meta.nequ, :] = fill_sparse!(A[1 : model.nls_meta.nequ, :], rows, cols, vals)
      @time A[model.nls_meta.nequ + 1 : model.nls_meta.nequ + model.meta.nvar, :] /= sqrt(3)
      # Update r
      @time r .= r_suiv
      @time sq_norm_r = norm(r)^2
      @time b[1 : model.nls_meta.nequ] .= r
      # Update stop
      mul!(Jtr, transpose(A[1 : model.nls_meta.nequ, :] ), r)
      stop = norm(Jtr)
    end

    ite += 1
  end
  print("\nNumber of iterations: ", ite, "\n")
  return x
end

"""
Update the values of a sparse matrix
"""
function fill_sparse!(A, rows, cols, vals)
  for k = 1 : length(rows)
    A[rows[k], cols[k]] = vals[k]
  end
  return A
end
