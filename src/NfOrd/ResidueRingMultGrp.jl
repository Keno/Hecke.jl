################################################################################
#
#  NfOrd/ResidueRingMultGrp.jl : Multiplicative group of Residue Rings
#
################################################################################

export multiplicative_group, multiplicative_group_generators

################################################################################
#
#  High Level Interface
#
################################################################################

doc"""
***
    multiplicative_group(Q::NfOrdQuoRing) -> GrpAbFinGen, Map{GrpAbFinGen, NfOrdQuoRing}
    unit_group(Q::NfOrdQuoRing) -> GrpAbFinGen, Map{GrpAbFinGen, NfOrdQuoRing}

> Returns the unit group of $Q$ as an abstract group $A$ and
> an isomorphism map $f \colon A \to Q^\times$.
"""
function multiplicative_group(Q::NfOrdQuoRing)
  if !isdefined(Q, :multiplicative_group)
    gens , structure , disc_log = _multgrp(Q)
    Q.multiplicative_group = AbToResRingMultGrp(Q,gens,structure,disc_log)
  end
  mQ = Q.multiplicative_group
  return domain(mQ), mQ
end

unit_group(Q::NfOrdQuoRing) = multiplicative_group(Q)

doc"""
***
    multiplicative_group_generators(Q::NfOrdQuoRing) -> Vector{NfOrdQuoRingElem}

> Return a set of generators for $Q^\times$.
"""
function multiplicative_group_generators(Q::NfOrdQuoRing)
  return multiplicative_group(Q).generators
end

function factor(Q::FacElem{NfOrdIdl, NfOrdIdlSet})
  if !all(isprime, keys(Q.fac))
    S = factor_coprime(Q)
    fac = Dict{NfOrdIdl, Int}()
    for (p, e)=S
      lp = factor(p)
      for q = keys(lp)
        fac[q] = Int(valuation(p, q)*e)
      end
    end
  else
    fac = Dict(p=>Int(e) for (p,e) = Q.fac)
  end
  return fac
end

################################################################################
#
#  Internals
#
################################################################################

doc"""
***
    _multgrp(Q::NfOrdQuoRing) -> (Vector{NfOrdQuoRingElem}, Vector{fmpz}, Function)

> Return generators, the snf structure and a discrete logarithm function for $Q^\times$.
"""
function _multgrp(Q::NfOrdQuoRing; method=nothing)
  gens = Vector{NfOrdQuoRingElem}()
  structt = Vector{fmpz}()
  disc_logs = Vector{Function}()
  i = ideal(Q)
  fac = factor(i)
  Q.factor = fac
  
  prime_power=Dict{NfOrdIdl, NfOrdIdl}()
  for (p,vp) in fac
    prime_power[p]= p^vp
  end
  
  
  for (p,vp) in fac
    gens_p , struct_p , dlog_p = _multgrp_mod_pv(p,vp;method=method)

    # Make generators coprime to other primes
    if length(fac) > 1
      i_without_p = 1
      for (p2,vp2) in fac
        (p != p2) && (i_without_p *= prime_power[p2])
      end

      alpha, beta = idempotents(prime_power[p],i_without_p)
      for i in 1:length(gens_p)
        g_pi_new = beta*gens_p[i] + alpha
        @hassert :NfOrdQuoRing 2 (g_pi_new - gens_p[i] in prime_power[p])
        @hassert :NfOrdQuoRing 2 (g_pi_new - 1 in i_without_p)
        gens_p[i] = g_pi_new
      end
    end

    gens_p = map(Q,gens_p)
    append!(gens,gens_p)
    append!(structt,struct_p)
    push!(disc_logs,dlog_p)
  end


  discrete_logarithm = function(x::NfOrdQuoRingElem)
    result = Vector{fmpz}()
    for dlog in disc_logs
      append!(result,dlog(x.elem))
    end
    return result
  end

  # Transform to SNF
  rels = matrix(diagm(structt))
  gens_trans, rels_trans, dlog_trans = snf_gens_rels_log(gens,rels,discrete_logarithm)
  return gens_trans, rels_trans, dlog_trans
end

################################################################################
#
#  Compute Multiplicative Group For Prime Powers
#
################################################################################

doc"""
***
    _multgrp_mod_pv(p::NfOrdIdl, v) -> (Vector{NfOrdElem}, Vector{fmpz}, Function)

> Given a prime ideal $p$ in a maximal order $\mathcal O$ and an integer $v > 0$, return generators,
> the group structure and a discrete logarithm function for $(\mathcal O/p^v)^\times$.
"""
function _multgrp_mod_pv(p::NfOrdIdl, v; method=nothing)
  @hassert :NfOrdQuoRing 2 isprime(p)
  @assert v >= 1
  gen_p, n_p, dlog_p = _multgrp_mod_p(p)
  if v == 1
    gens = [gen_p]
    structt = [n_p]
    discrete_logarithm = function(x::NfOrdElem) return [dlog_p(x)] end
  else
    gens_pv, struct_pv , dlog_pv = _1_plus_p_mod_1_plus_pv(p,v;method=method)
    obcs = prod(Set(struct_pv)) # order of biggest cyclic subgroup
    g_p_obcs = powermod(gen_p,obcs,p.gen_one^v)
    gens = [[g_p_obcs] ; gens_pv]

    structt = [[n_p] ; struct_pv]

    obcs_inv = gcdx(obcs,n_p)[2]
    discrete_logarithm = function(x::NfOrdElem)
      r = mod(dlog_p(x)*obcs_inv,n_p)
      x *= g_p_obcs^mod(-r,n_p)
      return [[r] ; dlog_pv(x)]
    end
  end
  return gens, structt, discrete_logarithm
end

################################################################################
#
#  Compute Multiplicative Group For Primes
#
################################################################################

# Compute (O_K/p)*
function _multgrp_mod_p(p::NfOrdIdl)
  @hassert :NfOrdQuoRing 2 isprime(p)
  O = order(p)
  n = norm(p) - 1
  gen = _primitive_element_mod_p(p)
  factor_n = factor(n)
  # TODO:
  # Compute the discrete logarithm in a finite field F with O/p \cong F.
  # Although P is always a prime, but not all of them work at the moment.
  # Make this work for all of them!
  if has_2_elem(p) && isprime_known(p)
    Q, mQ = ResidueField(O, p)
    gen_quo = mQ(gen)
    discrete_logarithm = function (x::NfOrdElem)
      y=mQ(x)
      if y==Q(1)
        return 0
      elseif y==Q(-1) && mod(n,2)==0
        return divexact(n,2)
      end
      if n<11
        res=1
        el=gen_quo
        while el!=y
          el*=gen_quo
          res+=1
        end
        return res
      else 
        return pohlig_hellman(gen_quo,n,y;factor_n=factor_n)
      end
    end
  else
    Q = NfOrdQuoRing(O,p)
    gen_quo = Q(gen)
    discrete_logarithm= function (x::NfOrdElem)
      y=mQ(x)
      if y==Q(1)
        return 0
      elseif y==Q(-1) && mod(n,2)==0
        return divexact(n,2)
      end
      if n<11
        res=1
        el=gen_quo
        while el!=y
          el*=gen_quo
          res+=1
        end
        return res
      else 
        return pohlig_hellman(gen_quo,n,y;factor_n=factor_n)
      end
    end
  end
  return gen, n, discrete_logarithm
end

function _primitive_element_mod_p(p::NfOrdIdl)
  @hassert :NfOrdQuoRing 2 isprime(p)
  O = order(p)
  Q , Q_map = quo(O,p)
  n = norm(p) - 1
  primefactors_n = collect(keys(factor(n).fac))
  while true
    x = rand(Q)
    x == 0 && continue
    order_too_small = false
    for l in primefactors_n
      if x^div(n, l) == 1
        order_too_small = true
        break
      end
    end
    order_too_small || return Q_map\x
  end
end

################################################################################
#
# Computation of (1+p)/(1+p^v)
#
################################################################################

# Compute (1+p)/(1+p^v)
function _1_plus_p_mod_1_plus_pv(p::NfOrdIdl, v; method=nothing)
  @hassert :NfOrdQuoRing 2 isprime(p)
  @assert v >= 1
  if method == :one_unit
    gens = nothing
    rels = nothing
    disc_log = nothing
    try
      gens, structt , disc_log = _one_unit_method(p,v)
      rels = matrix(diagm(structt))
    catch
      warn("Skipped p = <$(p.gen_one),$(p.gen_two)>, v = $(v)")
      gens, rels, disc_log = _iterative_method(p,v)
    end
  elseif method == :quadratic
    gens, rels, disc_log = _iterative_method(p,v;base_method=:quadratic,use_p_adic=false)
  elseif method == :artin_hasse
    gens, rels, disc_log = _iterative_method(p,v;base_method=:artin_hasse,use_p_adic=false)
  elseif method == :p_adic
    gens, rels, disc_log = _iterative_method(p,v;use_p_adic=true)
  else
    gens, rels, disc_log = _iterative_method(p,v)
  end

  @assert size(rels) == (length(gens),length(gens))
  @vtime :RayFacElem 1 gens_snf , struct_snf , disc_log_snf = snf_gens_rels_log(gens, rels, disc_log, p^v)

  return gens_snf, struct_snf, disc_log_snf
end

################################################################################
#
#  Iterative Method for (1+p^u)/(1+p^v)
#
################################################################################

function _iterative_method(p::NfOrdIdl, v; base_method=nothing, use_p_adic=true)
  return _iterative_method(p,1,v;base_method=base_method,use_p_adic=use_p_adic)
end

function _iterative_method(p::NfOrdIdl, u, v; base_method=nothing, use_p_adic=true)
  @hassert :NfOrdQuoRing 2 isprime(p)
  @assert v >= u >= 1
  pnum = minimum(p)
  if use_p_adic
    e = valuation(pnum,p)
    k0 = 1 + div(fmpz(e),(pnum-1))
  end
  g = Vector{NfOrdElem}()
  M = zero_matrix(FlintZZ,0,0)
  dlogs = Vector{Function}()

  l = u
  pl = p^l

  while l != v
    k = l
    pk = pl

    if use_p_adic && k>=k0
      next_method = _p_adic_method
      l = v
    elseif base_method == :quadratic
      next_method = _quadratic_method
      l = min(2*k,v)
    elseif base_method == :_one_unit
      next_method = _one_unit_method
      if use_p_adic
        l = min(k0,v)
      else
        l = v
      end
    else
      next_method = _artin_hasse_method
      l = min(pnum*k,v)
    end

    d = Int(div(fmpz(l),k))
    pl = l == d*k ? pk^d : p^l
    h,N,disc_log = next_method(p,k,l;pu=pk,pv=pl)

    g,M = _expand(g,M,h,N,disc_log,pl)
    push!(dlogs,disc_log)
  end

  Q = NfOrdQuoRing(order(pl),pl)
  discrete_logarithm = function(b::NfOrdElem)
    b = Q(b)
    a = []
    k = 1
    for i in 1:length(dlogs)
      a_ = dlogs[i](b.elem)
      prod = 1
      for j in 1:length(a_)
        prod *= Q(g[k])^a_[j]
        k += 1
      end
      a = [a ; a_]
      b = divexact(b,prod)
    end
    return a
  end

  return g, M, discrete_logarithm
end

function _calculate_steps(stepsize,maximum)
  @assert stepsize > 1
  @assert maximum >= 1
  steps = [maximum]
  step = maximum
  while step > 1
    step = ceil(step//(stepsize))
    insert!(steps,1,step)
  end
  return steps
end

function _expand(g,M,h,N,disc_log,pl)
  isempty(g) && return h,N
  isempty(h) && return g,M
  P = _compute_P(g,M,h,N,disc_log,pl)
  Z = zero_matrix(FlintZZ,rows(N),cols(M))
  M = [M -P ; Z N]
  g = [g ; h]
  return g,M
end

function _compute_P(g,M,h,N,disc_log,pl)
  O = order(pl)
  O_mod_pl , O_mod_pl_map = quo(O,pl)

  Mg = Vector{NfOrdElem}(length(g))
  for i in 1:rows(M)
    Mg[i] = preimage(O_mod_pl_map,prod([ O_mod_pl_map(g[j])^M[i,j] for j in 1:length(g)]))
  end

  P = zero_matrix(FlintZZ,rows(M),cols(N))
  for i in 1:rows(P)
    b = Mg[i]
    alpha = disc_log(b)
    for j in 1:cols(P)
      P[i,j] = alpha[j]
    end
  end

  @hassert :NfOrdQuoRing 2 Mg == begin
    Ph = Vector{NfOrdElem}(rows(P))
    for i in 1:rows(P)
      Ph[i] = preimage(O_mod_pl_map,prod([ O_mod_pl_map(h[j])^P[i,j] for j in 1:length(h)]))
    end
    Ph
  end
  return P
end

function _pu_mod_pv(pu,pv)
  h = copy(basis(pu))
  N = basis_mat(pv)*basis_mat_inv(pu)
  @hassert :NfOrdQuoRing 2 den(N) == 1
  return h, num(N)
end

function _ideal_disc_log(x::NfOrdElem, basis_mat_inv::FakeFmpqMat)
  x_vector = transpose(matrix(FlintZZ, degree(parent(x)), 1, elem_in_basis(x)))
  x_fakemat = FakeFmpqMat(x_vector, fmpz(1))
  res_fakemat = x_fakemat * basis_mat_inv
  den(res_fakemat) != 1 && error("Element is in the ideal")
  res_mat = num(res_fakemat)
  @assert size(res_mat)[1] == 1
  return vec(Array(res_mat))
end

function _ideal_disc_log(x::NfOrdElem, ideal::NfOrdIdl)
  parent(x) != order(ideal) && error("Order of element and ideal must be equal")
  return _ideal_disc_log(x, basis_mat_inv(ideal))
end

# Let p be a prime ideal above a prime number pnum. Let e = v_p(pnum) be
# its ramification index. If b > a >= e/(pnum-1) this function computes
# the structure of (1+p^a)/(1+p^b) as an abelian group.
function _1_plus_pa_mod_1_plus_pb_structure(p::NfOrdIdl,a,b)
  b > a >= 1 || return false, nothing
  @hassert :NfOrdQuoRing 2 isprime(p)
  O = order(p)
  pnum = minimum(p)
  e = valuation(O(pnum),p)
  k0 = 1 + div(fmpz(e),(pnum-1))
  a >= k0 || return false, nothing
  Q = NfOrdQuoRing(O,p^(b-a))
  return true, group_structure(Q)
end

################################################################################
#
# Quadratic Method for (1+p^u)/(1+p^v)
#
################################################################################

# Compute generators, a relation matrix and a function to compute discrete
# logarithms for (1+p^u)/(1+p^v), where 2*u >= v >= u >= 1
function _quadratic_method(p::NfOrdIdl, u, v; pu=p^u, pv=p^v)
  @hassert :NfOrdQuoRing 2 isprime(p)
  @assert 2*u >= v >= u >= 1
  g,M = _pu_mod_pv(pu,pv)
  map!(x -> x + 1, g, g)
  discrete_logarithm = function(x) _ideal_disc_log(mod(x-1,pv),basis_mat_inv(pu)) end
  return g, M, discrete_logarithm
end


################################################################################
#
# Artin-Hasse Method for (1+p^u)/(1+p^v)
#
################################################################################

# Compute generators, a relation matrix and a function to compute discrete
# logarithms for (1+p^u)/(1+p^v), where p is a prime ideal over pnum
# and pnum*u >= v >= u >= 1
function _artin_hasse_method(p::NfOrdIdl, u, v; pu=p^u, pv=p^v)
  @hassert :NfOrdQuoRing 2 isprime(p)
  pnum = minimum(p)
  @assert pnum*u >= v >= u >= 1
  g,M = _pu_mod_pv(pu,pv)
  map!(x->artin_hasse_exp(pv,x), g, g)
  discrete_logarithm = function(x) return _ideal_disc_log(artin_hasse_log(x,pv),basis_mat_inv(pu)) end
  return g, M, discrete_logarithm
end

function artin_hasse_exp(pl::NfOrdIdl, x::NfOrdElem)
  @assert order(pl) == parent(x)
  O = order(pl)
  Q = NfOrdQuoRing(O,pl)
  x = Q(x)
  return artin_hasse_exp(x).elem
end

function artin_hasse_exp(x::NfOrdQuoRingElem)
  Q = parent(x)
  pl = ideal(Q)
  fac = factor(minimum(pl))
  @assert length(fac) == 1
  pnum = collect(keys(fac.fac))[1]
  s = 1
  fac_i = 1
  for i in 1:pnum-1
    fac_i *= Q(i)
    s += divexact(x^i,fac_i)
  end
  return s
end

function artin_hasse_log(y::NfOrdElem, pl::NfOrdIdl)
  @assert order(pl) == parent(y)
  O = order(pl)
  Q = NfOrdQuoRing(O,pl)
  y = Q(y)
  return artin_hasse_log(y).elem
end

function artin_hasse_log(y::NfOrdQuoRingElem)
  Q = parent(y)
  pl = ideal(Q)
  fac = factor(minimum(pl))
  @assert length(fac) == 1
  pnum = collect(keys(fac.fac))[1]
  x = y-1
  s = Q(0)
  t= Q(1)
  for i in 1:pnum-1
    t *=x
    if i % 2 == 0
      s -= divexact(t,Q(i))
    else 
      s += divexact(t,Q(i))
    end
  end
  return s
end

################################################################################
#
# p-Adic Method for (1+p^u)/(1+p^v)
#
################################################################################

# Compute generators, a relation matrix and a function to compute discrete
# logarithms for (1+p)/(1+p^v) if 1 >= k0, where p is a prime ideal over pnum,
# e the p-adic valuation of pnum, and k0 = 1 + div(e,pnum-1)
function _p_adic_method(p::NfOrdIdl, v; pv=p^v)
  return _p_adic_method(p,1,v)
end

# Compute generators, a relation matrix and a function to compute discrete
# logarithms for (1+p^u)/(1+p^v) if u >= k0, where p is a prime ideal over pnum,
# e the p-adic valuation of pnum, and k0 = 1 + div(e,pnum-1)
function _p_adic_method(p::NfOrdIdl, u, v; pu=p^u, pv=p^v)
  @assert v > u >= 1
  @hassert :NfOrdQuoRing 2 isprime(p)
  pnum = minimum(p)
  e = valuation(pnum,p)
  k0 = 1 + div(fmpz(e),(pnum-1))
  @assert u >= k0
  g,M = _pu_mod_pv(pu,pv)
  map!(x->p_adic_exp(p,v,x;pv=pv), g, g)
  discrete_logarithm = function(b) _ideal_disc_log(p_adic_log(p,v,b;pv=pv),basis_mat_inv(pu)) end
  return g, M, discrete_logarithm
end

function p_adic_exp(p::NfOrdIdl, v, x::NfOrdElem; pv=p^v)
  O = parent(x)
  x == 0 && return O(1)
  Q = NfOrdQuoRing(O,pv)
  pnum = minimum(p)
  val_p_x = valuation(x,p)
  e = valuation(pnum,p)
  max_i = ceil(Int, v / (val_p_x - (e/(Float64(pnum)-1)))) 
  val_p_maximum = Int(max_i*val_p_x) + 1
  Q_ = NfOrdQuoRing(O,p^val_p_maximum)
  x = Q_(x)
  s = one(Q)
  inc = 1
  val_p_xi = 0
  val_p_fac_i = 0
  i_old = 0
  for i in 1:max_i
    val_pnum_i = valuation(fmpz(i), pnum)
    val_p_i = val_pnum_i * e
    val_p_fac_i += val_p_i
    val_p_xi += val_p_x
    val_p_xi - val_p_fac_i >= v && continue
    i_prod = prod((i_old+1):i)
    inc = divexact(inc*x^(i-i_old),i_prod)
    s += Q(inc.elem)
    i_old = i
  end
  return s.elem
end

function p_adic_exp2(x::NfOrdQuoRingElem)
  Q1 = parent(x)
  x = x.elem
  Q = NfOrdQuoRing(parent(x),ideal(Q1)^2) # TODO
  x = Q(x)
  s = Q(1)
  i = 1
  fac_i = Q(1)
  while true
    inc = divexact(x^i,fac_i)
    inc == 0 && break
    s += inc
    i += 1
    fac_i *= i
  end
  return Q1(s.elem)
end

function p_adic_log(p,v,y::NfOrdElem;pv=p^v)
  O = parent(y)
  y == 1 && return O(0)
  Q = NfOrdQuoRing(O,pv)
  pnum = minimum(p)
  x = y - 1
  e = valuation(pnum, p)
  val_p_x = valuation(x, p)
  s = zero(Q)
  xi = one(O)
  i_old = 0
  val_p_xi = 0
  pnum = Int(pnum)
  for i in [ 1:v ; (v+pnum-(v%pnum)):pnum:pnum*v ]
    val_pnum_i = valuation(i, pnum)
    val_p_i = val_pnum_i * e
    val_p_xi += val_p_x
    val_p_xi - val_p_i >= v && continue
    xi *= x^(i-i_old)
    fraction = divexact(xi.elem_in_nf,i)
    inc = divexact(Q(O(num(fraction))),Q(O(den(fraction))))
    isodd(i) ? s+=inc : s-=inc
    i_old = i
  end
  return s.elem
end

function p_adic_log2(y::NfOrdQuoRingElem)
  Q1 = parent(y)
  y = y.elem
  Q = NfOrdQuoRing(parent(y),ideal(Q1)^2) # TODO
  x = Q(y-1)
  s = Q(0)
  i = 1
  while true
    inc = divexact(x^i,i)
    inc *= Q(-1)^(i-1)
    inc == 0 && break
    s += inc
    i += 1
  end
  return Q1(s.elem)
end


################################################################################
#
#  SNF For Multiplicative Groups
#
################################################################################

doc"""
***
    snf_gens_rels_log(gens::Vector,
                      rels::fmpz_mat,
                      dlog::Function) -> (Vector, fmpz_mat, Function)
    snf_gens_rels_log(gens::Vector{NfOrdElem},
                      rels::fmpz_mat,
                      dlog::Function,
                      i::NfOrdIdl) -> (Vector{NfOrdElem}, fmpz_mat, Function)

> Return the smith normal form of a mulitplicative group.

> The group is represented by generators, a relation matrix
> and a function to compute the discrete logarithm with respect to the generators.
> All trivial components of the group will be removed.
> If the generators are of type `NfOrdElem` and an ideal `i` is supplied,
> all transformations of the generators will be computed modulo `i`.
"""
function snf_gens_rels_log(gens::Vector, rels::fmpz_mat, dlog::Function)
  n, m = size(rels)
  @assert length(gens) == m
  (n==0 || m==0) && return gens, fmpz[], dlog
  @assert typeof(gens[1])==NfOrdQuoRingElem
  G=GrpAbFinGen(rels)
  S,mS=snf(G)
  
  function disclog(x)

    y=dlog(x)
    z=fmpz[s for s in y]
    a=(mS\(G(z)))
    return fmpz[a[j] for j=1:ngens(S)]
  end
  gens_snf=typeof(gens)(ngens(S))
  for i=1:ngens(S)
    x=(mS(S[i])).coeff
    for j=1:ngens(G)
      x[1,j]=mod(x[1,j],S.snf[end])
    end
    y=parent(gens[1])(1)
    for j=1:ngens(G)
      y*=gens[j]^(x[1,j])
    end
    gens_snf[i]= y
  end
  @assert typeof(S.snf)!=typeof(rels)
  return gens_snf, S.snf, disclog
  
#=
  if issnf(rels)
    gens_snf = gens
    rels_snf = rels
    dlog_snf = dlog
  else
    if !ishnf(rels)
      rels = hnf(rels)
    end
    rels_hnf = hnf(rels)
    rels_snf, _, V = snf_with_transform(rels_hnf, false, true)
    @assert size(rels_snf) == (n,m)
    @assert size(V) == (m,m)
    V_inv = inv(V)

    # Reduce V_inv
    rels_lll = lll(rels_hnf)
    Ln, Ld = pseudo_inv(rels_lll)
    R = V_inv * Ln
    for j in 1:cols(R)
      for i in 1:rows(R)
        R[i,j] = round(R[i,j]//Ld)
      end
    end
    V_inv = V_inv - R * rels_lll

    gens_snf = typeof(gens)(m)
    for i in 1:m
      pos_exp = 1
      neg_exp = 1
      for j in 1:m
        if V_inv[i,j] >= 0
          pos_exp *= gens[j]^V_inv[i,j]
        else
          neg_exp *= gens[j]^(-V_inv[i,j])
        end
      end
      if neg_exp != 1 # TODO remove this
        gens_snf[i] = divexact(pos_exp,neg_exp)
      else
        gens_snf[i] = pos_exp
      end
    end
    T = Array(V')
    discrete_log = function(x) T * dlog(x) end
    dlog_snf = discrete_log
  end

  # Count trivial components
  max_one = 0
  for i in 1:m
    if rels_snf[i,i] != 1
      max_one = i-1
      break
    end
  end

  # Remove trivial components and empty relations
  if (max_one!=0) || (n!=m)
    rels_trans = zero_matrix(FlintZZ,n-max_one,n-max_one)
    for i in 1:rows(rels_trans)
      for j in 1:cols(rels_trans)
        rels_trans[i,j] = rels_snf[max_one+i,max_one+j]
      end
    end
  else
    rels_trans = rels_snf
  end

  # Remove trivial components and reduce logarithm modulo relations
  D = Vector{fmpz}([rels_trans[i,i] for i in 1:cols(rels_trans)])
  if (max_one!=0)
    gens_trans = gens_snf[max_one+1:end]
    discrete_logarithm = function(x) mod.(Vector{fmpz}(dlog_snf(x)[max_one+1:end]), D) end
    dlog_trans = discrete_logarithm
  else
    gens_trans = gens_snf
    dlog_trans = (x -> mod.(Vector{fmpz}(dlog_snf(x)), D))
  end

  return gens_trans, rels_trans, dlog_trans
  =#
end

function snf_gens_rels_log(gens::Vector{NfOrdElem}, rels::fmpz_mat, dlog::Function, i::NfOrdIdl)
  Q , Qmap = quo(order(i),i)
  gens_quo = map(Q,gens)
  gens_trans, rels_trans, dlog_trans = snf_gens_rels_log(gens_quo,rels,dlog)
  @assert typeof(rels_trans)==Array{fmpz,1}
  return map(x->Qmap\x,gens_trans), rels_trans, dlog_trans
end

################################################################################
#
#  Discrete Logarithm In Cyclic Groups
#
################################################################################
# TODO compare with implementations in UnitsModM.jl

doc"""
***
    baby_step_giant_step(g, n, h) -> fmpz
    baby_step_giant_step(g, n, h, cache::Dict) -> fmpz

> Computes the discrete logarithm $x$ such that $h = g^x$.

> $g$ is a generator of order less than or equal to $n$
> and $h$ has to be generated by $g$.
> If a dictionary `cache` is supplied, it will be used to story the result
> of the first step. This allows to speed up subsequent calls with
> the same $g$ and $n$.
"""
function baby_step_giant_step(g, n, h, cache::Dict)
  @assert typeof(g) == typeof(h)
  n = BigInt(n)
  m = ceil(BigInt, sqrt(n))
  if isempty(cache)
    it = g^0
    for j in 0:m
      cache[it] = j
      it *= g
    end
  end
  if typeof(g) == fq_nmod
    b = g^(-fmpz(m))
  else
    b = g^(-m)
  end
  y = h
  for i in 0:m-1
    if haskey(cache, y)
      return fmpz(mod(i*m + cache[y], n))
    else
      y *= b
    end
  end
  error("Couldn't find discrete logarithm")
end

function baby_step_giant_step(gen, n, a)
  cache = Dict{typeof(gen), BigInt}()
  return baby_step_giant_step(gen, n, a, cache)
end

doc"""
***
    pohlig_hellman(g, n, h; factor_n=factor(n)) -> fmpz

> Computes the discrete logarithm $x$ such that $h = g^x$.

> $g$ is a generator of order $n$ and $h$ has to be generated by $g$.
> The factorisation of $n$ can be supplied via `factor_n` if
> it is already known.
"""
function pohlig_hellman(g, n, h; factor_n=factor(n))
  @assert typeof(g) == typeof(h)
  n == 1 && return fmpz(0)
  results = Vector{Tuple{fmpz,fmpz}}()
  for (p,v) in factor_n
    pv = p^v
    r = div(n,pv)
    c = _pohlig_hellman_prime_power(g^r,p,v,h^r)
    push!(results,(fmpz(c),fmpz(pv)))
  end
  return crt(results)[1]
end

function _pohlig_hellman_prime_power(g,p,v,h)
  cache = Dict{typeof(g), BigInt}()
  p_i = 1
  p_v_min_i_min_1 = p^(v-1)
  g_ = g^(p^(v-1))
  a = baby_step_giant_step(g_,p,h^(p^(v-1)),cache)
  h *= g^-a
  for i in 1:v-1
    p_i *= p
    p_v_min_i_min_1 = div(p_v_min_i_min_1,p)
    ai = baby_step_giant_step(g_,p,h^p_v_min_i_min_1,cache)
    ai_p_i = ai * p_i
    a += ai_p_i
    h *= g^(-ai_p_i)
  end
  return a
end

################################################################################
#
#  Other Things
#
################################################################################

import Nemo.crt

doc"""
***
    crt(l::Vector{(Int,Int})) -> (fmpz, fmpz)
    crt(l::Vector{(fmpz,fmpz})) -> (fmpz, fmpz)

> Find $r$ and $m$ such that $r \equiv r_i (\mod m_i)$ for all $(r_i,m_i) \in l$
> and $m$ is the product of al $m_i$.
"""
function crt(l::Vector{Tuple{T,T}}) where T<:Union{fmpz,Int}
  isempty(l) && error("Input vector mustn't be empty")
  X = fmpz(l[1][1])
  M = fmpz(l[1][2])
  for (x,m) in l[2:end]
    X = crt(X,M,x,m)
    M *= m
  end
  return X, M
end
