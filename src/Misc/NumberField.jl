import Nemo.sub!, Base.gcd 
export induce_rational_reconstruction, induce_crt, root, roots,
       number_field, ismonic, pure_extension, ispure_extension,
       iskummer_extension, cyclotomic_field, wildanger_field, 
       compositum

add_verbose_scope(:PolyFactor)       
add_verbose_scope(:CompactPresentation)       
add_assert_scope(:CompactPresentation)       

if Int==Int32
  global const p_start = 2^30
else
  global const p_start = 2^60
end

################################################################################
#
#  fmpq_poly with denominator 1 to fmpz_poly
#
################################################################################


function (a::FmpzPolyRing)(b::fmpq_poly)
  (denominator(b) != 1) && error("denominator has to be 1")
  z = a()
  ccall((:fmpq_poly_get_numerator, :libflint), Void,
              (Ptr{fmpz_poly}, Ptr{fmpq_poly}), &z, &b)
  return z
end

doc"""
  basis(K::AnticNumberField)

> A Q-basis for K, ie. 1, x, x^2, ... as elements of K
"""
function basis(K::AnticNumberField)
  n = degree(K)
  g = gen(K);
  d = Array{typeof(g)}(n)
  b = K(1)
  for i = 1:n-1
    d[i] = b
    b *= g
  end
  d[n] = b
  return d
end

###########################################################################
# modular poly gcd and helpers
###########################################################################

function inner_crt(a::fmpz, b::fmpz, up::fmpz, pq::fmpz, pq2::fmpz = fmpz(0))
  #1 = gcd(p, q) = up + vq
  # then u = modinv(p, q)
  # vq = 1-up. i is up here
  #crt: x = a (p), x = b(q) => x = avq + bup = a(1-up) + bup
  #                              = (b-a)up + a
  if !iszero(pq2)
    r = mod(((b-a)*up + a), pq)
    if r > pq2
      return r-pq
    else
      return r
    end
  else
    return mod(((b-a)*up + a), pq)
  end
end

function induce_inner_crt(a::nf_elem, b::nf_elem, pi::fmpz, pq::fmpz, pq2::fmpz = fmpz(0))
  c = parent(a)()
  ca = fmpz()
  cb = fmpz()
  for i=0:degree(parent(a))-1
    Nemo.num_coeff!(ca, a, i)
    Nemo.num_coeff!(cb, b, i)
    Hecke._num_setcoeff!(c, i, inner_crt(ca, cb, pi, pq, pq2))
  end
  return c
end

doc"""
  induce_crt(a::Generic.Poly{nf_elem}, p::fmpz, b::Generic.Poly{nf_elem}, q::fmpz) -> Generic.Poly{nf_elem}, fmpz

> Given polynomials $a$ defined modulo $p$ and $b$ modulo $q$, apply the CRT
> to all coefficients recursively.
> Implicitly assumes that $a$ and $b$ have integral coefficients (ie. no
> denominators).
"""
function induce_crt(a::Generic.Poly{nf_elem}, p::fmpz, b::Generic.Poly{nf_elem}, q::fmpz, signed::Bool = false)
  c = parent(a)()
  pi = invmod(p, q)
  mul!(pi, pi, p)
  pq = p*q
  if signed
    pq2 = div(pq, 2)
  else
    pq2 = fmpz(0)
  end
  for i=0:max(degree(a), degree(b))
    setcoeff!(c, i, induce_inner_crt(coeff(a, i), coeff(b, i), pi, pq, pq2))
  end
  return c, pq
end

doc"""
  induce_rational_reconstruction(a::Generic.Poly{nf_elem}, M::fmpz) -> bool, Generic.Poly{nf_elem}

> Apply rational reconstruction to the coefficients of $a$. Implicitly assumes
> the coefficients to be integral (no checks done)
> returns true iff this is successful for all coefficients.
"""
function induce_rational_reconstruction(a::Generic.Poly{nf_elem}, M::fmpz)
  b = parent(a)()
  for i=0:degree(a)
    fl, x = rational_reconstruction(coeff(a, i), M)
    if fl
      setcoeff!(b, i, x)
    else
      return false, b
    end
  end
  return true, b
end

doc"""
  gcd(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem}) -> Generic.Poly{nf_elem}

> A modular $\gcd$
"""
function gcd(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem})
  # modular kronnecker assumes a, b !=n 0
  if iszero(a)
    if iszero(b)
      return b
    else
      return  inv(lead(b))*b
    end
  elseif iszero(b)
    return inv(lead(a))*a
  end

  g= gcd_modular_kronnecker(a, b)
  return inv(lead(g))*g  # we want it monic...
end

# There is some weird type instability
function gcd_modular(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem})
  # naive version, kind of
  # polys should be integral
  # rat recon maybe replace by known den if poly integral (Kronnecker)
  # if not monic, scale by gcd
  # remove content?
  a = a*(1//leading_coefficient(a))
  b = b*(1//leading_coefficient(b))
  global p_start
  p = p_start
  K = base_ring(parent(a))
  @assert parent(a) == parent(b)
  g = zero(a)
  d = fmpz(1)
  while true
    p = next_prime(p)
    me = modular_init(K, p)
    t = Hecke.modular_proj(a, me)
    fp = deepcopy(t)::Array{fq_nmod_poly, 1}  # bad!!!
    gp = Hecke.modular_proj(b, me)
    gp = [gcd(fp[i], gp[i]) for i=1:length(gp)]::Array{fq_nmod_poly, 1}
    gc = Hecke.modular_lift(gp, me)::Generic.Poly{nf_elem}
    if isone(gc)
      return parent(a)(1)
    end
    if d == 1
      g = gc
      d = fmpz(p)
    else
      if degree(gc) < degree(g)
        g = gc
        d = fmpz(p)
      elseif degree(gc) > degree(g)
        continue
      else
        g, d = induce_crt(g, d, gc, fmpz(p))
      end
    end
    fl, gg = induce_rational_reconstruction(g, d)
    if fl  # not optimal
      r = mod(a, gg)
      if iszero(r)
        r = mod(b, gg)
        if iszero(r)
          return gg
        end
      end
    end
  end
end

import Base.gcdx

#similar to gcd_modular, but avoids rational reconstruction by controlling
#a/the denominator
function gcd_modular_kronnecker(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem})
  # rat recon maybe replace by known den if poly integral (Kronnecker)
  # if not monic, scale by gcd
  # remove content?
  a = a*(1//leading_coefficient(a))
  da = Base.reduce(lcm, [denominator(coeff(a, i)) for i=0:degree(a)])
  b = b*(1//leading_coefficient(b))
  db = Base.reduce(lcm, [denominator(coeff(b, i)) for i=0:degree(b)])
  d = gcd(da, db)
  a = a*da
  b = b*db
  K = base_ring(parent(a))
  fsa = evaluate(derivative(K.pol), gen(K))*d
  #now gcd(a, b)*fsa should be in the equation order...
  global p_start
  p = p_start
  K = base_ring(parent(a))
  @assert parent(a) == parent(b)
  g = zero(a)
  d = fmpz(1)
  last_g = parent(a)(0)
  while true
    p = next_prime(p)
    local me, fp, gp, fsap
    try 
      me = modular_init(K, p)
      fp = deepcopy(Hecke.modular_proj(a, me))  # bad!!!
      gp = Hecke.modular_proj(b, me)
      fsap = Hecke.modular_proj(fsa, me)
    catch ee
      if typeof(ee) != Hecke.BadPrime
        rethrow(ee)
      end
      continue
    end
    gp = [fsap[i] * gcd(fp[i], gp[i]) for i=1:length(gp)]
    gc = Hecke.modular_lift(gp, me)
    if isone(gc)
      return parent(a)(1)
    end
    if d == 1
      g = gc
      d = fmpz(p)
    else
      if degree(gc) < degree(g)
        g = gc
        d = fmpz(p)
      elseif degree(gc) > degree(g)
        continue
      else
        g, d = induce_crt(g, d, gc, fmpz(p), true)
      end
    end
    if g == last_g
      r = mod(a, g)
      if iszero(r)
        r = mod(b, g)
        if iszero(r)
          return g
        end
      end
    else
      last_g = g
    end
  end
end

#seems to be faster than gcdx - if problem large enough.
#rational reconstructio is expensive - enventually
#TODO: figure out the denominators in advance. Resultants?

function gcdx_modular(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem})
  a = a*(1//leading_coefficient(a))
  b = b*(1//leading_coefficient(b))
  global p_start
  p = p_start
  K = base_ring(parent(a))
  @assert parent(a) == parent(b)
  g = zero(a)
  d = fmpz(1)
  last_g = parent(a)(0)
  while true
    p = next_prime(p)
    me = modular_init(K, p)
    fp = deepcopy(Hecke.modular_proj(a, me))  # bad!!!
    gp = Hecke.modular_proj(b, me)
    ap = similar(gp)
    bp = similar(gp)
    for i=1:length(gp)
      gp[i], ap[i], bp[i] = gcdx(fp[i], gp[i])
    end
    gc = Hecke.modular_lift(gp, me)
    aa = Hecke.modular_lift(ap, me)
    bb = Hecke.modular_lift(bp, me)
    if d == 1
      g = gc
      ca = aa
      cb = bb
      d = fmpz(p)
    else
      if degree(gc) < degree(g)
        g = gc
        ca = aa
        cb = bb
        d = fmpz(p)
      elseif degree(gc) > degree(g)
        continue
      else
        g, dd = induce_crt(g, d, gc, fmpz(p))
        ca, dd = induce_crt(ca, d, aa, fmpz(p))
        cb, d = induce_crt(cb, d, bb, fmpz(p))
      end
    end
    fl, ccb = Hecke.induce_rational_reconstruction(cb, d)
    if fl
      fl, cca = Hecke.induce_rational_reconstruction(ca, d)
    end
    if fl
      fl, gg = Hecke.induce_rational_reconstruction(g, d)
    end
    if fl
      r = mod(a, g)
      if iszero(r)
        r = mod(b, g)
        if iszero(r) && ((cca*a + ccb*b) == gg)
          return gg, cca, ccb
        end
      end
    end
  end
end


function ismonic(a::PolyElem)
  return isone(lead(a))
end

function eq_mod(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem}, d::fmpz)
  e = degree(a) == degree(b)
  K= base_ring(parent(a))
  i=0
  while e && i<= degree(a)
    j = 0
    while e && j<degree(K)
      e = e && (numerator(coeff(coeff(a, i), j)) - numerator(coeff(coeff(b, i), j))) % d == 0
      j += 1
    end
    i += 1
  end
  return e
end

#similar to gcd_modular, but avoids rational reconstruction by controlling
#a/the denominator using resultant. Faster than above, but still slow.
#mainly due to the generic resultant. Maybe use only deg-1-primes??
#fact: g= gcd(a, b) and 1= gcd(a/g, b/g) = u*(a/g) + v*(b/g)
#then u*res(a/g, b/g) is mathematically integeral, same for v
#scaling by f'(a) makes it i nthe equation order
#
# missing/ next attempt:
#  write invmod using lifting
#  write gcdx using lifting (lin/ quad)
#  try using deg-1-primes only (& complicated lifting)
#
function gcdx_mod_res(a::Generic.Poly{nf_elem}, b::Generic.Poly{nf_elem})
  a = a*(1//leading_coefficient(a))
  da = Base.reduce(lcm, [denominator(coeff(a, i)) for i=0:degree(a)])
  b = b*(1//leading_coefficient(b))
  db = Base.reduce(lcm, [denominator(coeff(a, i)) for i=0:degree(a)])
  d = gcd(da, db)
  a = a*da
  b = b*db
  K = base_ring(parent(a))
  fsa = evaluate(derivative(K.pol), gen(K))*d
  #now gcd(a, b)*fsa should be in the equation order...
  global p_start
  p = p_start
  K = base_ring(parent(a))
  @assert parent(a) == parent(b)
  g = zero(parent(a))
  d = fmpz(1)
  r = zero(K)
  fa = zero(parent(a))
  fb = zero(parent(b))
  last_g = (parent(a)(0), parent(a)(0), parent(a)(0), parent(a)(0))

  while true
    p = next_prime(p)
    me = modular_init(K, p)
    fp = deepcopy(Hecke.modular_proj(a, me))  # bad!!!
    gp = (Hecke.modular_proj(b, me))
    fsap = (Hecke.modular_proj(fsa, me))
    g_ = similar(fp)
    fa_ = similar(fp)
    fb_ = similar(fp)
    r_ = Array{fq_nmod}(length(fp))
    for i=1:length(gp)
      g_[i], fa_[i], fb_[i] = gcdx(fp[i], gp[i])
      r_[i] = resultant(div(fp[i], g_[i]), div(gp[i], g_[i]))
      g_[i] *= fsap[i]
      fa_[i] *= (fsap[i]*r_[i])
      fb_[i] *= (fsap[i]*r_[i])
    end
    rc = Hecke.modular_lift(r_, me)
    gc = Hecke.modular_lift(g_, me)
    fac = Hecke.modular_lift(fa_, me)
    fbc = Hecke.modular_lift(fb_, me)
    if d == 1
      g = gc
      r = rc
      fa = fac
      fb = fbc
      d = fmpz(p)
    else
      if degree(gc) < degree(g)
        g = gc
        r = rc
        fa = fac
        fb = fbc
        d = fmpz(p)
      elseif degree(gc) > degree(g)
        continue
      else
        g, d1 = induce_crt(g, d, gc, fmpz(p), true)
        fa, d1 = induce_crt(fa, d, fac, fmpz(p), true)

        r = Hecke.induce_inner_crt(r, rc, d*invmod(d, fmpz(p)), d1, div(d1, 2))
        fb, d = induce_crt(fb, d, fbc, fmpz(p), true)

      end
    end
    if (g, r, fa, fb) == last_g
      if g*r == fa*a + fb*b
        return g*r, fa, fb ## or normalise to make gcd monic??
      else
        last_g = (g, r, fa, fb)
      end
    else
      last_g = (g, r, fa, fb)
    end
  end
end

###########################################################################

import Nemo.issquarefree

function issquarefree(x::Generic.Poly{nf_elem})
  return degree(gcd(x, derivative(x))) == 0
end

###########################################################################
function nf_poly_to_xy(f::PolyElem{Nemo.nf_elem}, x::PolyElem, y::PolyElem)
  K = base_ring(f)
  Qy = parent(K.pol)

  res = zero(parent(y))
  for i=degree(f):-1:0
    res *= y
    res += evaluate(Qy(coeff(f, i)), x)
  end
  return res
end

function inv(a::RelSeriesElem{<:Nemo.FieldElem}) 
#function inv(a::RelSeriesElem{nf_elem})
  @assert valuation(a)==0
  # x -> x*(2-xa) is the lifting recursion
  x = parent(a)(inv(coeff(a, 0)))
  set_prec!(x, 1)
  p = precision(a)
  la = [p]
  while la[end]>1
    push!(la, div(la[end]+1, 2))
  end

  two = parent(a)(base_ring(a)(2))
  set_prec!(two, p)

  n = length(la)-1
  y = parent(a)()
  while n>0
    set_prec!(x, la[n])
    set_prec!(y, la[n])
#    y = mul!(y, a, x)
#    y = two-y #sub! is missing...
#    x = mul!(x, x, y)
    x = x*(two-x*a)
    n -=1 
  end
  return x
end

function log(a::RelSeriesElem{<:Nemo.FieldElem}) 
  @assert valuation(a)==0 
  return integral(derivative(a)*inv(a))
end

function exp(a::RelSeriesElem{<:Nemo.FieldElem})
  @assert valuation(a) >0
  R = base_ring(parent(a))
  x = parent(a)([R(1)], 1, 2, 0)
  p = precision(a)
  la = [p]
  while la[end]>1
    push!(la, div(la[end]+1, 2))
  end

  one = parent(a)([R(1)], 1, 2, 0)

  n = length(la)-1
  # x -> x*(1-log(a)+a) is the recursion
  while n>0
    set_prec!(x, la[n])
    set_prec!(one, la[n])
    x = x*(one - log(x) + a) # TODO: can be optimized...
    n -=1 
  end
  return x
end


doc"""
    derivative(f::RelSeriesElem{T}) -> RelSeriesElem
> Return the derivative of the power series $f$.
"""
function derivative(f::RelSeriesElem{T}) where T
  g = parent(f)()
  set_prec!(g, precision(f)-1)
  v = valuation(f)
  if v==0
    for i=1:Nemo.pol_length(f)
      setcoeff!(g, i-1, (i+v)*Nemo.polcoeff(f, i))
    end
    Nemo.set_val!(g, 0)
  else
    for i=0:Nemo.pol_length(f)
      setcoeff!(g, i, (i+v)*Nemo.polcoeff(f, i))
    end
    Nemo.set_val!(g, v-1)
  end
  Nemo.renormalize!(g)  
  return g
end

doc"""
    integral(f::RelSeriesElem{T}) -> RelSeriesElem
> Return the integral of the power series $f$.
"""
function Nemo.integral(f::RelSeriesElem{T}) where T
  g = parent(f)()
  set_prec!(g, precision(f)+1)
  v = valuation(f)
  for i=0:Nemo.pol_length(f)
    setcoeff!(g, i, divexact(Nemo.polcoeff(f, i), i+v+1))
  end
  Nemo.set_val!(g, v+1)
  Nemo.renormalize!(g) 
  return g
end

doc"""
    polynomial_to_power_sums(f::PolyElem{T}, n::Int=degree(f)) -> Array{T, 1}
> Uses Newton (or Newton-Girard) formulas to compute the first $n$
> power sums from the coefficients of $f$.
"""
function polynomial_to_power_sums(f::PolyElem{T}, n::Int=degree(f)) where T <: FieldElem
  d = degree(f)
  R = base_ring(f)
  S = PowerSeriesRing(R, n+1, "gen(S)")[1]
  #careful: converting to power series and derivative do not commute
  #I also don't quite get this: I thought this was just the log,
  #but it isn't
  A = S([coeff(reverse(derivative(f)), i) for i=0:d-1], d, n+1, 0)
  B = S([coeff(reverse(f), i) for i=0:d], d+1, n+1, 0)
  L = A*inv(B)
  s = [coeff(L, i) for i=1:n]
  return s
end

#plain vanilla recursion
function polynomial_to_power_sums(f::PolyElem{T}, n::Int=degree(f)) where T 
  d = degree(f)
  R = base_ring(f)
  E = T[(-1)^i*coeff(f, d-i) for i=0:min(d, n)] #should be the elementary symm.
  while length(E) <= n
    push!(E, R(0))
  end
  P = T[]

  push!(P, E[1+1])
  for k=2:n
    push!(P, (-1)^(k-1)*k*E[k+1] + sum((-1)^(k-1+i)*E[k-i+1]*P[i] for i=1:k-1))
  end
  return P
end

doc"""
    power_sums_to_polynomial(P::Array{T, 1}) -> PolyElem{T}
> Uses the Newton (or Newton-Girard) identities to obtain the polynomial
> coefficients (the elementary symmetric functions) from the power sums.
"""
function power_sums_to_polynomial(P::Array{T, 1}) where T <: FieldElem
  d = length(P)
  R = parent(P[1])
  S = PowerSeriesRing(R, d, "gen(S)")[1]
  s = S(P, length(P), d, 0)
  if !false
    r = - integral(s)
    r = exp(r)
  end

  if false
    r = S(T[R(1), -P[1]], 2, 2, 0) 
    la = [d+1]
    while la[end]>1
      push!(la, div(la[end]+1, 2))
    end
    n = length(la)-1
    while n > 0
      set_prec!(r, la[n])
      rr = derivative(r)*inv(r)
      md = -(rr+s)
      m = S([R(1)], 1, la[n], 0)+integral(md)
      r *= m
      n -= 1
    end
    println("new exp $r")
  end
  d = Nemo.pol_length(r)
  v = valuation(r)
  @assert v==0
  while d>=0 && iszero(Nemo.polcoeff(r, d))
    d -= 1
  end
  return PolynomialRing(R, cached = false)[1]([Nemo.polcoeff(r, d-i) for i=0:d])
end

function power_sums_to_polynomial(P::Array{T, 1}) where T
  E = T[1]
  R = parent(P[1])
  last_non_zero = 0
  for k=1:length(P)
    push!(E, divexact(sum((-1)^(i-1)*E[k-i+1]*P[i] for i=1:k), R(k)))
    if E[end] != 0
      last_non_zero = k
    end
  end
  E = E[1:last_non_zero+1]
  d = length(E) #the length of the resulting poly...
  for i=1:div(d, 2)
    E[i], E[d-i+1] = (-1)^(d-i)*E[d-i+1], (-1)^(i-1)*E[i]
  end
  return PolynomialRing(R, cached = false)[1](E)
end

doc"""
  norm(f::PolyElem{nf_elem}) -> fmpq_poly

> The norm of f, i.e. the product of all conjugates of f taken coefficientwise.
"""
function norm(f::PolyElem{nf_elem})
  Kx = parent(f)
  K = base_ring(f)
  if degree(f) > 10 # TODO: find a good cross-over
    P = polynomial_to_power_sums(f, degree(f)*degree(K))
    PQ = [trace(x) for x=P]
    return power_sums_to_polynomial(PQ)
  end

  Qy = parent(K.pol)
  y = gen(Qy)
  Qyx, x = PolynomialRing(Qy, "x", cached = false)

  Qx = PolynomialRing(FlintQQ, "x")[1]
  Qxy = PolynomialRing(Qx, "y", cached = false)[1]

  T = evaluate(K.pol, gen(Qxy))
  h = nf_poly_to_xy(f, gen(Qxy), gen(Qx))
  return resultant(T, h)
end

function norm(f::PolyElem{T}) where T <: NfRelElem
  Kx = parent(f)
  K = base_ring(f)

  P = polynomial_to_power_sums(f, degree(f)*degree(K))
  PQ = [trace(x) for x=P]
  return power_sums_to_polynomial(PQ)
end


doc"""
  factor(f::fmpz_poly, K::NumberField) -> Fac{Generic.Poly{nf_elem}}
  factor(f::fmpq_poly, K::NumberField) -> Fac{Generic.Poly{nf_elem}}

> The factorisation of f over K (using Trager's method).
"""
function factor(f::fmpq_poly, K::AnticNumberField)
  Ky, y = PolynomialRing(K, cached = false)
  return factor(evaluate(f, y))
end

function factor(f::fmpz_poly, K::AnticNumberField)
  Ky, y = PolynomialRing(K, cached = false)
  Qz, z = PolynomialRing(FlintQQ)
  return factor(evaluate(Qz(f), y))
end


doc"""
  factor(f::PolyElem{nf_elem}) -> Fac{Generic.Poly{nf_elem}}

> The factorisation of f (using Trager's method).
"""
function factor(f::PolyElem{nf_elem})
  Kx = parent(f)
  K = base_ring(f)
  f == 0 && error("poly is zero")
  f_orig = deepcopy(f)
  @vprint :PolyFactor 1 "Factoring $f\n"
  @vtime :PolyFactor 2 g = gcd(f, derivative(f'))
  if degree(g) > 0
    f = div(f, g)
  end

  f = f*(1//lead(f))

  k = 0
  g = f
  N = 0

  while true
    @vtime :PolyFactor 2 N = norm(g)

    if !isconstant(N) && issquarefree(N)
      break
    end

    k = k + 1

    g = compose(f, gen(Kx) - k*gen(K))
  end

  @vtime :PolyFactor 2 fac = factor(N)

  res = Dict{PolyElem{nf_elem}, Int64}()

  for i in keys(fac.fac)
    t = zero(Kx)
    for j in 0:degree(i)
      t = t + K(coeff(i, j))*gen(Kx)^j
    end
    t = compose(t, gen(Kx) + k*gen(K))
    @vtime :PolyFactor 2 t = gcd(f, t)
    res[t] = 1
  end

  r = Fac{typeof(f)}()
  r.fac = res
  r.unit = Kx(1)

  if f != f_orig
    global p_start
    p = p_start
    @vtime :PolyFactor 2 while true
      p = next_prime(p)
      me = modular_init(K, p, max_split=1)
      fp = modular_proj(f, me)[1]
      if issquarefree(fp)
        fp = deepcopy(modular_proj(f_orig, me)[1])
        for k in keys(res)
          gp = modular_proj(k, me)[1]
          res[k] = valuation(fp, gp)
        end
        r.fac = res
        # adjust the unit of the factorization
        r.unit = one(Kx) * lead(f_orig)//prod((lead(p) for (p, e) in r))
        return r
      end
    end
  end
  r.unit = one(Kx)* lead(f_orig)//prod((lead(p) for (p, e) in r))
  return r
end

################################################################################
#
# Operations for nf_elem
#
################################################################################

function gen!(r::nf_elem)
   a = parent(r)
   ccall((:nf_elem_gen, :libantic), Void,
         (Ptr{nf_elem}, Ptr{AnticNumberField}), &r, &a)
   return r
end

function one!(r::nf_elem)
   a = parent(r)
   ccall((:nf_elem_one, :libantic), Void,
         (Ptr{nf_elem}, Ptr{AnticNumberField}), &r, &a)
   return r
end

function one(r::nf_elem)
   a = parent(r)
   return one(a)
end

function zero(r::nf_elem)
   return zero(parent(r))
end

*(a::nf_elem, b::Integer) = a * fmpz(b)

doc"""
***
   norm_div(a::nf_elem, d::fmpz, nb::Int) -> fmpz

> Computes divexact(norm(a), d) provided the result has at most nb bits.
> Typically, a is in some ideal and d is the norm of the ideal.
"""
function norm_div(a::nf_elem, d::fmpz, nb::Int)
   z = fmpq()
   #CF the resultant code has trouble with denominators,
   #   this "solves" the problem, but it should probably be
   #   adressed in c
   de = denominator(a)
   n = degree(parent(a))
   ccall((:nf_elem_norm_div, :libantic), Void,
         (Ptr{fmpq}, Ptr{nf_elem}, Ptr{AnticNumberField}, Ptr{fmpz}, UInt),
         &z, &(a*de), &a.parent, &(d*de^n), UInt(nb))
   return z
end

function sub!(a::nf_elem, b::nf_elem, c::nf_elem)
   ccall((:nf_elem_sub, :libantic), Void,
         (Ptr{nf_elem}, Ptr{nf_elem}, Ptr{nf_elem}, Ptr{AnticNumberField}),

         &a, &b, &c, &a.parent)
end

function ^(x::nf_elem, y::fmpz)
  if y < 0
    return inv(x)^(-y)
  elseif y == 0
    return parent(x)(1)
  elseif y == 1
    return deepcopy(x)
  elseif mod(y, 2) == 0
    z = x^(div(y, 2))
    return z*z
  elseif mod(y, 2) == 1
    return x^(y-1) * x
  end
end

doc"""
***
    roots(f::fmpz_poly, K::AnticNumberField) -> Array{nf_elem, 1}
    roots(f::fmpq_poly, K::AnticNumberField) -> Array{nf_elem, 1}

> Computes all roots in $K$ of a polynomial $f$. It is assumed that $f$ is is non-zero,
> squarefree and monic.
"""
function roots(f::fmpz_poly, K::AnticNumberField, max_roots::Int = degree(f))
  Ky, y = PolynomialRing(K, cached = false)
  return roots(evaluate(f, y), max_roots)
end

function roots(f::fmpq_poly, K::AnticNumberField, max_roots::Int = degree(f))
  Ky, y = PolynomialRing(K, cached = false)
  return roots(evaluate(f, y), max_roots)
end

elem_in_nf(a::nf_elem) = a

doc"""
***
    roots(f::Generic.Poly{nf_elem}) -> Array{nf_elem, 1}

> Computes all roots of a polynomial $f$. It is assumed that $f$ is is non-zero,
> squarefree and monic.
"""
function roots(f::Generic.Poly{nf_elem}, max_roots::Int = degree(f); do_lll::Bool = false, do_max_ord::Bool = true)
  @assert issquarefree(f)

  #TODO: implement for equation order....
  #TODO: use max_roots

  if degree(f) == 1
    return [-trailing_coefficient(f)//lead(f)]
  end

  get_d = x -> denominator(x)
  if do_max_ord
    O = maximal_order(base_ring(f))
    if do_lll
      O = lll(O)
    end
    get_d = x-> denominator(x, O)
  end

  d = degree(f)

  deno = get_d(coeff(f, d))
  for i in (d-1):-1:0
    ai = coeff(f, i)
    if !iszero(ai)
      deno = lcm(deno, get_d(ai))
    end
  end

  g = deno*f

  if do_max_ord
    Ox, x = PolynomialRing(O, "x", cached = false)
    goverO = Ox([ O(coeff(g, i)) for i in 0:d])
  else
    goverO = g
  end  

  if !isone(lead(goverO))
    deg = degree(f)
    a = lead(goverO)
    b = one(O)
    for i in deg-1:-1:0
      setcoeff!(goverO, i, b*coeff(goverO, i))
      b = b*a
    end
    setcoeff!(goverO, deg, one(O))
    r = _roots_hensel(goverO, max_roots)
    return [ divexact(elem_in_nf(y), elem_in_nf(a)) for y in r ]
  end

  A = _roots_hensel(goverO, max_roots)

  return [ elem_in_nf(y) for y in A ]
end


doc"""
***
    ispower(a::nf_elem, n::Int) -> Bool, nf_elem

> Determines whether $a$ has an $n$-th root. If this is the case,
> the root is returned.
"""
function ispower(a::nf_elem, n::Int)
  #println("Compute $(n)th root of $a")

  @assert n>0
  if n==1
    return true, a
  end
  if iszero(a)
    return true, a
  end

  d = denominator(a)
  rt = _roots_hensel(a*d^n, n, 1)

  if length(rt)>0
    return true, rt[1]//d
  else
    return false, zero(a)
  end
end

doc"""
***
    root(a::nf_elem, n::Int) -> nf_elem

> Computes the $n$-th root of $a$. Throws an error if this is not possible.
"""
function root(a::nf_elem, n::Int)
  fl, rt = ispower(a, n)
  if fl
    return rt
  end

  error("$a has no $n-th root")
end

doc"""
    roots(a::nf_elem, n::Int) -> Array{nf_elem, 1}
> Compute all $n$-th roots of $a$, possibly none.
"""
function roots(a::nf_elem, n::Int)
  #println("Compute $(n)th root of $a")

  @assert n>0
  if n==1
    return [a]
  end
  if iszero(a)
    return [a]
  end

  d = denominator(a)
  rt = _roots_hensel(a*d^n, n)

  return [x//d for x = rt]
end


function root(a::NfOrdElem, n::Int)
  fl, rt = ispower(a.elem_in_nf, n)
  if fl
    O = parent(a)
    if denominator(a, O) == 1
      return O(rt)
    end  
  end

  error("$a has no $n-th root")
end

function numerator(a::nf_elem)
   const _one = fmpz(1)
   z = copy(a)
   ccall((:nf_elem_set_den, :libantic), Void,
         (Ptr{nf_elem}, Ptr{fmpz}, Ptr{AnticNumberField}),
         &z, &_one, &a.parent)
   return z
end

copy(d::nf_elem) = deepcopy(d)

################################################################################
#
#  Torsion units and related functions
#
################################################################################

doc"""
***
    istorsion_unit(x::nf_elem, checkisunit::Bool = false) -> Bool

> Returns whether $x$ is a torsion unit, that is, whether there exists $n$ such
> that $x^n = 1$.
>
> If `checkisunit` is `true`, it is first checked whether $x$ is a unit of the
> maximal order of the number field $x$ is lying in.
"""
function istorsion_unit(x::nf_elem, checkisunit::Bool = false)
  if checkisunit
    _isunit(x) ? nothing : return false
  end

  K = parent(x)
  d = degree(K)
  c = conjugate_data_arb(K)
  r, s = signature(K)

  while true
    @vprint :UnitGroup 2 "Precision is now $(c.prec) \n"
    l = 0
    @vprint :UnitGroup 2 "Computing conjugates ... \n"
    cx = conjugates_arb(x, c.prec)
    A = ArbField(c.prec, false)
    for i in 1:r
      k = abs(cx[i])
      if k > A(1)
        return false
      elseif isnonnegative(A(1) + A(1)//A(6) * log(A(d))//A(d^2) - k)
        l = l + 1
      end
    end
    for i in 1:s
      k = abs(cx[r + i])
      if k > A(1)
        return false
      elseif isnonnegative(A(1) + A(1)//A(6) * log(A(d))//A(d^2) - k)
        l = l + 1
      end
    end

    if l == r + s
      return true
    end
    refine(c)
  end
end

doc"""
***
    torsion_unit_order(x::nf_elem, n::Int)

> Given a torsion unit $x$ together with a multiple $n$ of its order, compute
> the order of $x$, that is, the smallest $k \in \mathbb Z_{\geq 1}$ such
> that $x^`k` = 1$.
>
> It is not checked whether $x$ is a torsion unit.
"""
function torsion_unit_order(x::nf_elem, n::Int)
  # This is lazy
  # Someone please change this
  y = deepcopy(x)
  for i in 1:n
    if y == 1
      return i
    end
    mul!(y, y, x)
  end
  error("Something odd in the torsion unit order computation")
end

################################################################################
#
#  Serialization
#
################################################################################

# This function can be improved by directly accessing the numerator
# of the fmpq_poly representing the nf_elem
doc"""
***
    write(io::IO, A::Array{nf_elem, 1}) -> Void

> Writes the elements of `A` to `io`. The first line are the coefficients of
> the defining polynomial of the ambient number field. The following lines
> contain the coefficients of the elements of `A` with respect to the power
> basis of the ambient number field.
"""
function write(io::IO, A::Array{nf_elem, 1})
  if length(A) == 0
    return
  else
    # print some useful(?) information
    print(io, "# File created by Hecke $VERSION_NUMBER, $(Base.Dates.now()), by function 'write'\n")
    K = parent(A[1])
    polring = parent(K.pol)

    # print the defining polynomial
    g = K.pol
    d = denominator(g)

    for j in 0:degree(g)
      print(io, coeff(g, j)*d)
      print(io, " ")
    end
    print(io, d)
    print(io, "\n")

    # print the elements
    for i in 1:length(A)

      f = polring(A[i])
      d = denominator(f)

      for j in 0:degree(K)-1
        print(io, coeff(f, j)*d)
        print(io, " ")
      end

      print(io, d)

      print(io, "\n")
    end
  end
end

doc"""
***
    write(file::String, A::Array{nf_elem, 1}, flag::ASCIString = "w") -> Void

> Writes the elements of `A` to the file `file`. The first line are the coefficients of
> the defining polynomial of the ambient number field. The following lines
> contain the coefficients of the elements of `A` with respect to the power
> basis of the ambient number field.
>
> Unless otherwise specified by the parameter `flag`, the content of `file` will be
> overwritten.
"""
function write(file::String, A::Array{nf_elem, 1}, flag::String = "w")
  f = open(file, flag)
  write(f, A)
  close(f)
end

# This function has a bad memory footprint
doc"""
***
    read(io::IO, K::AnticNumberField, ::Type{nf_elem}) -> Array{nf_elem, 1}

> Given a file with content adhering the format of the `write` procedure,
> this functions returns the corresponding object of type `Array{nf_elem, 1}` such that
> all elements have parent $K$.

**Example**

    julia> Qx, x = FlintQQ["x"]
    julia> K, a = NumberField(x^3 + 2, "a")
    julia> write("interesting_elements", [1, a, a^2])
    julia> A = read("interesting_elements", K, Hecke.nf_elem)
"""
function read(io::IO, K::AnticNumberField, ::Type{Hecke.nf_elem})
  Qx = parent(K.pol)

  A = Array{nf_elem, 1}()

  i = 1

  for ln in eachline(io)
    if ln[1] == '#'
      continue
    elseif i == 1
      # the first line read should contain the number field and will be ignored
      i = i + 1
    else
      coe = map(Hecke.fmpz, split(ln, " "))
      t = fmpz_poly(Array(slice(coe, 1:(length(coe) - 1))))
      t = Qx(t)
      t = divexact(t, coe[end])
      push!(A, K(t))
      i = i + 1
    end
  end

  return A
end

doc"""
***
    read(file::String, K::AnticNumberField, ::Type{nf_elem}) -> Array{nf_elem, 1}

> Given a file with content adhering the format of the `write` procedure,
> this functions returns the corresponding object of type `Array{nf_elem, 1}` such that
> all elements have parent $K$.

**Example**

    julia> Qx, x = FlintQQ["x"]
    julia> K, a = NumberField(x^3 + 2, "a")
    julia> write("interesting_elements", [1, a, a^2])
    julia> A = read("interesting_elements", K, Hecke.nf_elem)
"""
function read(file::String, K::AnticNumberField, ::Type{Hecke.nf_elem})
  f = open(file, "r")
  A = read(f, K, Hecke.nf_elem)
  close(f)
  return A
end


function dot(a::Array{nf_elem, 1}, b::Array{fmpz, 1})
  d = zero(parent(a[1]))
  t = zero(d)
  for i=1:length(a)
    Nemo.mul!(t, a[i], b[i])
    Nemo.add!(d, d, t)
  end
  return d
end

mutable struct nf_elem_deg_1_raw
  num::Int  ## fmpz!
  den::Int
end

mutable struct nf_elem_deg_2_raw
  nu0::Int  ## fmpz - actually an fmpz[3]
  nu1::Int
  nu2::Int
  den::Int
end

mutable struct nf_elem_deg_n_raw  #actually an fmpq_poly_raw
  A::Ptr{Int} # fmpz
  den::Int # fmpz
  alloc::Int
  len::Int
end

mutable struct nmod_t
  n::Int
  ni::Int
  norm::Int
end

#nf_elem is a union of the three types above
#ignores the denominator completely

function nf_elem_to_nmod_poly_no_den!(r::nmod_poly, a::nf_elem)
  d = degree(a.parent)
  zero!(r)
  p = r.mod_n
  if d == 1
    ra = pointer_from_objref(a)
    s = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Void}, UInt), ra, p)
    ccall((:nmod_poly_set_coeff_ui, :libflint), Void, (Ptr{nmod_poly}, Int, UInt), &r, 0, s)
  elseif d == 2
    ra = pointer_from_objref(a)
    s = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Void}, UInt), ra, p)
    ccall((:nmod_poly_set_coeff_ui, :libflint), Void, (Ptr{nmod_poly}, Int, UInt), &r, 0, s)
    s = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Void}, UInt), ra + sizeof(Int), p)
    ccall((:nmod_poly_set_coeff_ui, :libflint), Void, (Ptr{nmod_poly}, Int, UInt), &r, 1, s)
  else
    ccall((:_fmpz_vec_get_nmod_poly, :libhecke), Void, (Ptr{nmod_poly}, Ptr{Int}, Int), &r, a.elem_coeffs, a.elem_length)
# this works without libhecke:
#    ccall((:nmod_poly_fit_length, :libflint), Void, (Ptr{nmod_poly}, Int), &r, a.elem_length)
#    ccall((:_fmpz_vec_get_nmod_vec, :libflint), Void, (Ptr{Void}, Ptr{Void}, Int, nmod_t), r._coeffs, a.elem_coeffs, a.elem_length, nmod_t(p, 0, 0))
#    r._length = a.elem_length
#    ccall((:_nmod_poly_normalise, :libflint), Void, (Ptr{nmod_poly}, ), &r)
  end
end

function nf_elem_to_nmod_poly_den!(r::nmod_poly, a::nf_elem)
  d = degree(a.parent)
  p = r.mod_n
  if d == 1
    ra = pointer_from_objref(a)
    den = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Void}, UInt), ra + sizeof(Int), p)
  elseif d == 2
    ra = pointer_from_objref(a)
    den = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Void}, UInt), ra + 3*sizeof(Int), p)
  else
    den = ccall((:fmpz_fdiv_ui, :libflint), UInt, (Ptr{Int}, UInt), &a.elem_den, p)
  end
  den = ccall((:n_invmod, :libflint), UInt, (UInt, UInt), den, p)
  nf_elem_to_nmod_poly_no_den!(r, a)
  mul!(r, r, den)
end

function nf_elem_to_nmod_poly(Rx::Nemo.NmodPolyRing, a::nf_elem)
  r = Rx()
  nf_elem_to_nmod_poly_den!(r, a)
  return r
end


(R::Nemo.NmodPolyRing)(a::nf_elem) = nf_elem_to_nmod_poly(R, a)

#now the same for fmpz_mod_poly

function nf_elem_to_fmpz_mod_poly_no_den!(r::fmpz_mod_poly, a::nf_elem)
  d = degree(a.parent)
  zero!(r)
  if d == 1
    ccall((:fmpz_mod_poly_fit_length, :libflint), Void, (Ptr{fmpz_mod_poly}, Int), &r, 1)
    ra = pointer_from_objref(a)
    ccall((:fmpz_mod, :libflint), Void, (Ptr{Void}, Ptr{Void}, Ptr{Int}), r.coeffs, ra, &r.p)
  elseif d == 2
    ccall((:fmpz_mod_poly_fit_length, :libflint), Void, (Ptr{fmpz_mod_poly}, Int), &r, 2)
    ra = pointer_from_objref(a)
    ccall((:fmpz_mod, :libflint), Void, (Ptr{Void}, Ptr{Void}, Ptr{Int}), r.coeffs, ra, &r.p)
    ccall((:fmpz_mod, :libflint), Void, (Ptr{Void}, Ptr{Void}, Ptr{Int}), r.coeffs+sizeof(Int), ra+sizeof(Int), &r.p)
    r.length = 2
    if coeff(r, 1) == 0
      if coeff(r, 0) == 0
        r.length == 0
      else
        r.length == 1
      end
    end
  else
    ccall((:fmpz_mod_poly_fit_length, :libflint), Void, (Ptr{fmpz_mod_poly}, Int), &r, a.elem_length)
    for i=0:a.elem_length-1
      ccall((:fmpz_mod, :libflint), Void, (Ptr{Void}, Ptr{Void}, Ptr{Int}), r.coeffs+sizeof(Int)*i, a.elem_coeffs+sizeof(Int)*i, &r.p)
    end
    r.length = a.elem_length
  end
  ccall((:_fmpz_mod_poly_normalise, :libflint), Void, (Ptr{fmpz_mod_poly}, ), &r)
end

function nf_elem_to_fmpz_mod_poly_den!(r::fmpz_mod_poly, a::nf_elem)
  d = degree(a.parent)
  nf_elem_to_fmpz_mod_poly_no_den!(r, a)
  dn = denominator(a)
  ccall((:fmpz_mod, :libflint), Void, (Ptr{fmpz}, Ptr{fmpz}, Ptr{Int}), &dn, &dn, &(r.p))
  ccall((:fmpz_invmod, :libflint), Void, (Ptr{fmpz}, Ptr{fmpz}, Ptr{Int}), &dn, &dn, &(r.p))
  ccall((:fmpz_mod_poly_scalar_mul_fmpz, :libflint), Void, (Ptr{fmpz_mod_poly}, Ptr{fmpz_mod_poly}, Ptr{fmpz}), &r, &r, &dn)
end

function nf_elem_to_fmpz_mod_poly(Rx::Nemo.FmpzModPolyRing, a::nf_elem)
  r = Rx()
  nf_elem_to_fmpz_mod_poly_den!(r, a)
  return r
end

(R::Nemo.FmpzModPolyRing)(a::nf_elem) = nf_elem_to_fmpz_mod_poly(R, a)


# Characteristic

characteristic(::AnticNumberField) = 0

function inv_lift_recon(a::nf_elem)  # not competitive....reconstruction is too slow
  p = next_prime(2^60)
  K = parent(a)
  me = modular_init(K, p)
  ap = Hecke.modular_proj(a, me)
  bp = Hecke.modular_lift([inv(x) for x = ap], me)
  pp = fmpz(p)

  fl, b = Hecke.rational_reconstruction(bp, pp)
  t = K()
  while !fl
#    @assert mod_sym(a*bp - 1, pp) == 0
    mul!(pp, pp, pp)
    mul!(t, a, bp)
    rem!(bp, pp)
    sub!(t, 2, t)
    mul!(bp, bp, t)
    rem!(bp, pp)
#    @assert mod_sym(a*bp - 1, pp) == 0
    fl, b = rational_reconstruction(bp, pp)
    if fl
      if b*a == 1
        return b
      end
      fl = false
    end
  end
  return b
end

import Hecke.mod_sym!, Hecke.rem!, Hecke.mod!, Hecke.mod, Hecke.rem

function mod_sym!(a::nf_elem, b::fmpz)
  mod_sym!(a, b, div(b, 2))
end

function mod_sym!(a::nf_elem, b::fmpz, b2::fmpz)
  z = fmpz()
  for i=0:a.elem_length-1
    Nemo.num_coeff!(z, a, i)
    rem!(z, z, b)
    if z >= b2
      sub!(z, z, b)
    end
    _num_setcoeff!(a, i, z)
  end
end

function mod!(z::fmpz, x::fmpz, y::fmpz)
  ccall((:fmpz_mod, :libflint), Void, (Ptr{fmpz}, Ptr{fmpz}, Ptr{fmpz}), &z, &x, &y)
  return z
end

function mod!(a::nf_elem, b::fmpz)
  z = fmpz()
  d = degree(parent(a))
  if d == 1
    Nemo.num_coeff!(z, a, 0)
    mod!(z, z, b)
    _num_setcoeff!(a, 0, z)
  elseif d == 2
    Nemo.num_coeff!(z, a, 0)
    mod!(z, z, b)
    _num_setcoeff!(a, 0, z)
    Nemo.num_coeff!(z, a, 1)
    mod!(z, z, b)
    _num_setcoeff!(a, 1, z)
    #Nemo.num_coeff!(z, a, 2)
    #mod!(z, z, b)
    #_num_setcoeff!(a, 2, z)
  else
    for i=0:a.elem_length-1
      Nemo.num_coeff!(z, a, i)
      mod!(z, z, b)
      _num_setcoeff!(a, i, z)
    end
  end
end

function mod(a::nf_elem, b::fmpz)
  c = deepcopy(a)
  mod!(c, b)
  return c
end

function rem!(a::nf_elem, b::fmpz)
  z = fmpz()
  for i=0:a.elem_length-1
    Nemo.num_coeff!(z, a, i)
    rem!(z, z, b)
    _num_setcoeff!(a, i, z)
  end
end

function rem(a::nf_elem, b::fmpz)
  c = deepcopy(a)
  rem!(c, b)
  return c
end

function mod_sym(a::nf_elem, b::fmpz)
  return mod_sym(a, b, div(b, 2))
end

function mod_sym(a::nf_elem, b::fmpz, b2::fmpz)
  c = deepcopy(a)
  mod_sym!(c, b, b2)
  return c
end

function inv_lift(a::nf_elem)  # better, but not enough
  p = next_prime(2^60)
  K = parent(a)
  me = modular_init(K, p)
  ap = modular_proj(a, me)
  bp = modular_lift([inv(x) for x = ap], me)
  pp = fmpz(p)
  fl, b = Hecke.rational_reconstruction(bp, pp)
  t = K()
  n = norm(a)
  while !fl
    Hecke.mul!(t, a, bp)
    Hecke.mul!(pp, pp, pp)
    rem!(t, pp)
    Hecke.sub!(t, 2, t)
    Hecke.mul!(bp, bp, t)
    rem!(t, pp)
    mul!(t, bp, n)
    mod_sym!(t, pp)
    if t*a == n
      return t//n
    end
  end
  return b
end

############################################################
# Better(?) norm computation in special situation...
############################################################
mutable struct NormCtx
  me::Array{modular_env, 1}
  nb::Int
  K::AnticNumberField
  ce::crt_env{fmpz}
  ln::Array{fmpz, 1}

  function NormCtx(K::AnticNumberField, nb::Int, deg_one::Bool = false)
    p = p_start
    me = Array{modular_env,1}()

    r = new()
    r.K = K
    r.nb = nb

    lp = fmpz[]

    while nb > 0
      local m
      while true
        p = next_prime(p)
        m = modular_init(K, p)
        if deg_one && length(m.rp) < degree(K)
          continue
        end
        break
      end
      push!(lp, fmpz(p))
      push!(me, m)
      nb = nb - nbits(p)
    end
    r.me = me
    r.ce = crt_env(lp)
    r.ln = Array{fmpz, 1}()
    for i = me
      push!(r.ln, fmpz(0))
    end
    return r
  end
end

import Nemo.mulmod, Nemo.invmod

function show(io::IO, a::NormCtx)
  println(io, "NormCtx for $(a.K) for $(a.nb) bits, using $(length(a.me)) primes")
end

function mulmod(a::UInt, b::UInt, n::UInt, ni::UInt)
  ccall((:n_mulmod2_preinv, :libflint), UInt, (UInt, UInt, UInt, UInt), a, b, n, ni)
end

function norm(a::nf_elem, N::NormCtx, div::fmpz = fmpz(1))
  ln = N.ln
  i = 1
  for m = N.me
    np = UInt(invmod(div, m.p))
    ap = modular_proj(a, m)
    for j=1:length(ap)
      # problem: norm costs memory (in fmpz formally, then new fq_nmod is created)
      np = mulmod(np, coeff(norm(ap[j]), 0), m.rp[1].mod_n, m.rp[1].mod_ninv)
    end
    N.ln[i] = np # problem: np is UInt, ln is not...
    i += 1
  end
  return crt_signed(N.ln, N.ce)
end


function israt(a::nf_elem)
  if degree(parent(a))==1
    return true
  end
  @assert degree(parent(a))>2 ## fails for 2 due to efficiency
  return a.elem_length<2
end

function resultant_mod(f::Generic.Poly{nf_elem}, g::Generic.Poly{nf_elem})
  global p_start
  p = p_start
  K = base_ring(parent(f))
  @assert parent(f) == parent(g)
  r = K()
  d = fmpz(1)
  last_r = K()
  first = true
  while true
    p = next_prime(p)
    me = modular_init(K, p)
    fp = deepcopy(Hecke.modular_proj(f, me))  # bad!!!
    gp = Hecke.modular_proj(g, me)
    rp = Array{fq_nmod}(length(gp))
    for i=1:length(gp)
      rp[i] = resultant(fp[i], gp[i])
    end
    rc = Hecke.modular_lift(rp, me)
    if d == 1
      r = rc
      d = fmpz(p)
    else
      r, d = induce_crt(r, d, rc, fmpz(p))
    end
    fl, ccb = Hecke.rational_reconstruction(r, d)
    if fl
      if first
        first = false
        last_r = ccb
#        println("first: $ccb")
      else
        if ccb == last_r
          return ccb
        else
#      println("fail2: $ccb")
          last_r = ccb
        end
      end
    else
#      println("fail")
    end
  end
end

function induce_crt(a::nf_elem, p::fmpz, b::nf_elem, q::fmpz, signed::Bool = false)
  c = parent(a)()
  pi = invmod(p, q)
  mul!(pi, pi, p)
  pq = p*q
  if signed
    pq2 = div(pq, 2)
  else
    pq2 = fmpz(0)
  end
  return induce_inner_crt(a, b, pi, pq, pq2), pq
end

#################################################################################################
#
#  Normal Basis
#
#################################################################################################

doc"""
***
    normal_basis(K::Nemo.AnticNumberField) -> nf_elem
> Given a number field K which is normal over Q, it returns 
> an element generating a normal basis of K over Q
"""
function normal_basis(K::Nemo.AnticNumberField)

  n=degree(K)
  Aut=Hecke.automorphisms(K)
  length(Aut) != degree(K) && error("The field is not normal over the rationals!")

  A=zero_matrix(FlintQQ, n, n)
  r=K(1)
  while true
  
    r=rand(basis(K),-n:n)
    for i=1:n
      y=Aut[i](r)
      for j=1:n
        A[i,j]=coeff(y,j-1)
      end
    end
    if det(A)!=0
      break
    end
  end
  return r
end

function norm(A::FacElem{NfOrdIdl, NfOrdIdlSet})
  b = Dict{fmpz, fmpz}()
  for (p, k) = A.fac
    n = norm(p)
    if haskey(b, n)
      b[n] += k
    else
      b[n] = k
    end
  end
  bb = FacElem(b)
  simplify!(bb)
  return evaluate(bb)
end

function norm(A::FacElem{NfOrdFracIdl, NfOrdFracIdlSet})
  b = Dict{fmpz, fmpz}()
  for (p, k) = A.fac
    n = norm(p)
    v = numerator(n)
    if haskey(b, v)
      b[v] += k
    else
      b[v] = k
    end
    v = denominator(n)
    if haskey(b, v)
      b[v] -= k
    else
      b[v] = -k
    end
  end
  bb = FacElem(b)
  simplify!(bb)
  return evaluate(bb)
end


function ==(A::NfOrdIdl, B::FacElem{NfOrdIdl, NfOrdIdlSet})
  C = inv(B)*A
  return isone(C)
end
==(B::FacElem{NfOrdIdl, NfOrdIdlSet}, A::NfOrdIdl) = A == B

function ==(A::NfOrdFracIdl, B::FacElem{NfOrdFracIdl, NfOrdFracIdlSet})
  C = A*inv(B)
  return isone(C)
end
==(B::FacElem{NfOrdFracIdl, NfOrdFracIdlSet}, A::NfOrdIdl) = A == B

function isone(A::NfOrdFracIdl)
  B = simplify(A)
  return B.den == 1 && isone(B.num)
end

function ==(A::FacElem{NfOrdFracIdl,NfOrdFracIdlSet}, B::FacElem{NfOrdFracIdl,NfOrdFracIdlSet})
  return isone(A*inv(B))
end
function ==(A::FacElem{NfOrdIdl,NfOrdIdlSet}, B::FacElem{NfOrdIdl,NfOrdIdlSet})
  return isone(A*inv(B))
end
function ==(A::FacElem{NfOrdIdl,NfOrdIdlSet}, B::FacElem{NfOrdFracIdl,NfOrdFracIdlSet})
  return isone(A*inv(B))
end

==(A::FacElem{NfOrdFracIdl,NfOrdFracIdlSet}, B::FacElem{NfOrdIdl,NfOrdIdlSet}) = B==A

==(A::NfOrdFracIdl, B::FacElem{NfOrdIdl,NfOrdIdlSet}) = isone(A*inv(B))

function *(A::FacElem{NfOrdIdl,NfOrdIdlSet}, B::FacElem{NfOrdFracIdl,NfOrdFracIdlSet})
  C = deepcopy(B)
  for (i,k) = A.fac
    C *= FacElem(Dict(i//1 => k))
  end
  return C
end
*(A::FacElem{NfOrdFracIdl,NfOrdFracIdlSet}, B::FacElem{NfOrdIdl,NfOrdIdlSet}) = B*A

function isone(A::FacElem{NfOrdIdl, NfOrdIdlSet})
  A = simplify(A)
  return length(A.fac) == 1 && isone(first(keys(A.fac)))
end

function isone(A::FacElem{NfOrdFracIdl, NfOrdFracIdlSet})
  A = simplify(A)
  return length(A.fac) == 1 && isone(first(keys(A.fac)))
end
doc"""
    simplify(K::AnticNumberField; canonical::Bool = false) -> AnticNumberField, NfToNfMor
 > Tries to find an isomorphic field $L$ given by a "nicer" defining polynomial.
 > By default, "nice" is defined to be of smaller index, testing is done only using
 > a LLL-basis of the maximal order.
 > If \texttt{canonical} is set to {{{true}}}, then a canonical defining
 > polynomial is found, where canonical is using the pari-definition of {{{polredabs}}}
 > in http://beta.lmfdb.org/knowledge/show/nf.polredabs.
 > Both version require a LLL reduced basis for the maximal order.
"""
function simplify(K::AnticNumberField; canonical::Bool = false)
  if canonical
    a, f = polredabs(K)
  else
    ZK = lll(maximal_order(K))
    I = index(ZK)^2
    D = discriminant(ZK)
    B = basis(ZK)
    b = ZK(gen(K))
    f = K.pol
    for i=1:length(B)
      ff = minpoly(B[i])
      if degree(ff) < degree(K)
        continue
      end
      id = div(discriminant(ff), D)
      if id<I
        b = B[i]
        I = id
        f = ff
      end
    end
    a = b.elem_in_nf
  end
  Qx,x=PolynomialRing(FlintQQ)
  L = number_field(Qx(f), cached=false)[1]
  m = NfToNfMor(L, K, a)
  return L, m
end

function factor(f::fmpq_poly, R::NmodRing)
  Rt, t = PolynomialRing(R, "t", cached=false)
  return factor(Rt(f))
end

function factor(f::fmpz_poly, R::NmodRing)
  Rt, t = PolynomialRing(R, "t", cached=false)
  return factor(Rt(f))
end

function roots(f::fmpq_poly, R::Nemo.FqNmodFiniteField)
  Rt, t = PolynomialRing(R, "t", cached=false)
  fp = FlintZZ["t"][1](f*denominator(f))
  fpp = Rt(fp)
  return roots(fpp)
end

function roots(f::fmpq_poly, R::Nemo.NmodRing)
  Rt, t = PolynomialRing(R, "t", cached=false)
  fp = FlintZZ["t"][1](f*denominator(f))
  fpp = Rt(fp)
  return roots(fpp)
end

function roots(f::T) where T <: Union{fq_nmod_poly, fq_poly} # should be in Nemo and
                                    # made available for all finite fields I guess.
  q = size(base_ring(f))
  x = gen(parent(f))
  if degree(f) < q
    x = powmod(x, q, f)-x
  else
    x = x^q-x
  end
  f = gcd(f, x)
  l = factor(f).fac
  return elem_type(base_ring(f))[-trailing_coefficient(x) for x = keys(l) if degree(x)==1]
end

function roots(f::PolyElem)
  lf = factor(f)
  return elem_type(base_ring(f))[-trailing_coefficient(x) for x= keys(lf.fac) if degree(x)==1]
end    

function setcoeff!(z::fq_nmod_poly, n::Int, x::fmpz)
   ccall((:fq_nmod_poly_set_coeff_fmpz, :libflint), Void,
         (Ptr{fq_nmod_poly}, Int, Ptr{fmpz}, Ptr{FqNmodFiniteField}),
         &z, n, &x, &base_ring(parent(z)))
     return z
end

 #a block is a partition of 1:n
 #given by the subfield of parent(a) defined by a
 #the embeddings used are in R
 #K = parent(a)
 # then K has embeddings into the finite field (parent of R[1])
 # given by the roots (in R) of the minpoly of K
 #integers in 1:n are in the same block iff a(R[i]) == a(R[j])
 #the length of such a block (system) is the degree of Q(a):Q, the length
 # of a block is the degree K:Q(a)
 # a is primitive iff the block system has length n
function _block(a::nf_elem, R::Array{fq_nmod, 1}, ap)
  c = FlintZZ()
  for i=0:a.elem_length
    Nemo.num_coeff!(c, a, i)
    setcoeff!(ap, i, c)
  end
#  ap = Ft(Zx(a*denominator(a)))
  s = [ap(x) for x = R]
  b = []
  a = IntSet()
  i = 0
  n = length(R)
  while i < n
    i += 1
    if i in a
      continue
    end
    z = s[i]
    push!(b, find(x->s[x] == z, 1:n))
    for j in b[end]
      push!(a, j)
    end
  end
  return b
end

#given 2 block systems b1, b2 for elements a1, a2, this computes the
#system for Q(a1, a2), the compositum of Q(a1) and Q(a2) as subfields of K
function _meet(b1, b2)
  b = []
  for i=b1
    for j = i
      for h = b2
        if j in h
          s = intersect(i, h)
          if ! (s in b)
            push!(b, s)
          end
        end
      end
    end
  end
  return b
end

function polredabs(K::AnticNumberField)
  #intended to implement 
  # http://beta.lmfdb.org/knowledge/show/nf.polredabs
  #as in pari
  #TODO: figure out the separation of T2-norms....
  ZK = lll(maximal_order(K))
  I = index(ZK)^2
  D = discriminant(ZK)
  B = basis(ZK)
  b = gen(K)
  f = K.pol
  
  p = 2^20
  d = 1
  while true
    p = next_prime(p)
    R = ResidueRing(FlintZZ, p, cached=false)
    lp = factor(K.pol, R)
    if any(t->t>1, values(lp.fac))
      continue
    end
    d = Base.reduce(lcm, 1, [degree(x) for x = keys(lp.fac)])
    if d < degree(f)^2
      break
    end
  end

  F, w = FiniteField(p, d, "w", cached=false)
  Ft, t = PolynomialRing(F, "t", cached=false)
  ap = Ft()
  R = roots(K.pol, F)
  Zx = FlintZZ["x"][1]
  n = degree(K)

  b = _block(B[1].elem_in_nf, R, ap)
  i = 2
  while length(b) < degree(K)
    bb = _block(B[i].elem_in_nf, R, ap)
    b = _meet(b, bb)
    i += 1
  end
  i -= 1
#  println("need to use at least the first $i basis elements...")
  pr = 100
  old = precision(BigFloat)
  E = 1
  while true
    setprecision(BigFloat, pr)
    try
      E = enum_ctx_from_ideal(ideal(ZK, 1), zero_matrix(FlintZZ, 1, 1), prec = pr, TU = BigFloat, TC = BigFloat)
      if E.C[end] + 0.0001 == E.C[end]  # very very crude...
        pr *= 2
        continue
      end
      break
    catch e
      if isa(e, InexactError)
        pr *= 2
        continue
      end
      rethrow(e)
    end
  end

  l = zeros(FlintZZ, n)
  l[i] = 1

  scale = 1.0
  enum_ctx_start(E, matrix(FlintZZ, 1, n, l), eps = 1.01)

  a = gen(K)
  all_a = [a]
  la = length(a)*BigFloat(E.t_den^2)
  Ec = BigFloat(E.c//E.d)
  eps = BigFloat(E.d)^(1//2)

  found_pe = false
  while !found_pe
    while enum_ctx_next(E)
#      @show E.x
      M = E.x*E.t
      q = elem_from_mat_row(K, M, 1, E.t_den)
      bb = _block(q, R, ap)
      if length(bb) < n
        continue
      end
      found_pe = true
#  @show    llq = length(q)
#  @show sum(E.C[i,i]*(BigFloat(E.x[1,i]) + E.tail[i])^2 for i=1:E.limit)/BigInt(E.t_den^2)
      lq = Ec - (E.l[1] - E.C[1, 1]*(BigFloat(E.x[1,1]) + E.tail[1])^2) #wrong, but where?
#      @show lq/E.t_den^2

      if lq < la + eps
        if lq > la - eps
          push!(all_a, q)
  #        @show "new one"
        else
          a = q
          all_a = [a]
          if lq/la < 0.8
  #          @show "re-init"
            enum_ctx_start(E, E.x, eps = 1.01)  #update upperbound
            Ec = BigFloat(E.c//E.d)
          end
          la = lq
  #        @show Float64(la/E.t_den^2)
        end  
      end
    end
    scale *= 2
    enum_ctx_start(E, matrix(FlintZZ, 1, n, l), eps = scale)
    Ec = BigFloat(E.c//E.d)
  end

  setprecision(BigFloat, old)
  all_f = [(x, minpoly(x)) for x=all_a]
  all_d = [abs(discriminant(x[2])) for x= all_f]
  m = minimum(all_d)

  L1 = all_f[find(i->all_d[i] == m, 1:length(all_d))]

  function Q1Q2(f::PolyElem)
    q1 = parent(f)()
    q2 = parent(f)()
    g = gen(parent(f))
    for i=0:degree(f)
      if isodd(i)
        q2 += coeff(f, i)*g^div(i, 2)
      else
        q1 += coeff(f, i)*g^div(i, 2)
      end
    end
    return q1, q2
  end
  function minQ(A::Tuple)
    a = A[1]
    f = A[2]
    q1, q2 = Q1Q2(f)
    if lead(q1)>0 && lead(q2) > 0
      return (-A[1], f(-gen(parent(f)))*(-1)^degree(f))
    else
      return (A[1], f)
    end
  end

  L2 = [minQ(x) for x=L1]

  function int_cmp(a, b)
    if a==b
      return 0
    end
    if abs(a) == abs(b)
      if a>b
        return 1
      else
        return -1
      end
    end
    return cmp(abs(a), abs(b))
  end

  function il(F, G)
    f = F[2]
    g = G[2]
    i = degree(f)
    while i>0 && int_cmp(coeff(f, i), coeff(g, i))==0 
      i -= 1
    end
    return int_cmp(coeff(f, i), coeff(g, i))<0
  end

  L3 = sort(L2, lt = il)

  return L3[1]
end

################################################################################
#
#  issubfield and isisomorphic
#
################################################################################

function _issubfield(K::AnticNumberField, L::AnticNumberField)
  f = K.pol
  g = L.pol
  Lx, x = L["x"]
  fL = Lx()
  for i = 0:degree(f)
    setcoeff!(fL, i, L(coeff(f, i)))
  end
  fac = factor(fL)
  for (a, b) in fac
    if degree(a) == 1
      c1 = coeff(a, 0)
      c2 = coeff(a, 1)
      h = parent(K.pol)(-c1*inv(c2))
      return true, NfToNfMor(K, L, h(gen(L)))
    end
  end
  return false, NfToNfMor(K, L, L())
end

doc"""
***
      issubfield(K::AnticNumberField, L::AnticNumberField) -> Bool, NfToNfMor

> Returns "true" and an injection from $K$ to $L$ if $K$ is a subfield of $L$.
> Otherwise the function returns "false" and a morphism mapping everything to 0.
"""
function issubfield(K::AnticNumberField, L::AnticNumberField)
  f = K.pol
  g = L.pol
  if mod(degree(g), degree(f)) != 0
    return false, NfToNfMor(K, L, L())
  end
  t = divexact(degree(g), degree(f))
  try
    OK = _get_maximal_order_of_nf(K)
    OL = _get_maximal_order_of_nf(L)
    if mod(discriminant(OL), discriminant(OK)^t) != 0
      return false, NfToNfMor(K, L, L())
    end
  catch e
    if !isa(e, AccessorNotSetError)
      rethrow(e)
    end
    # We could factorize the discriminant of f, but we only test small primes.
    p = 3
    df = discriminant(f)
    dg = discriminant(g)
    while p < 10000
      if p > df || p > dg
        break
      end
      if mod(valuation(df, p), 2) == 0
        p = next_prime(p)
        continue
      end
      if mod(dg, p^t) != 0
        return false, NfToNfMor(K, L, L())
      end
      p = next_prime(p)
    end
  end
  return _issubfield(K, L)
end

doc"""
***
      isisomorphic(K::AnticNumberField, L::AnticNumberField) -> Bool, NfToNfMor

> Returns "true" and an isomorphism from $K$ to $L$ if $K$ and $L$ are isomorphic.
> Otherwise the function returns "false" and a morphism mapping everything to 0.
"""
function isisomorphic(K::AnticNumberField, L::AnticNumberField)
  f = K.pol
  g = L.pol
  if degree(f) != degree(g)
    return false, NfToNfMor(K, L, L())
  end
  if signature(K) != signature(L)
    return false, NfToNfMor(K, L, L())
  end
  try
    OK = _get_maximal_order_of_nf(K)
    OL = _get_maximal_order_of_nf(L)
    if discriminant(OK) != discriminant(OL)
      return false, NfToNfMor(K, L, L())
    end
  catch e
    if !isa(e, AccessorNotSetError)
      rethrow(e)
    end
    t = discriminant(f)//discriminant(g)
    if !issquare(numerator(t)) || !issquare(denominator(t))
      return false, NfToNfMor(K, L, L())
    end
  end
  return _issubfield(K, L)
end

doc"""
   compositum(K::AnticNumberField, L::AnticNumberField) -> AnticNumberField, Map, Map
> Assuming $L$ is normal (which is not checked), compute the compositum $C$ of the
> 2 fields together with the embedding of $K \to C$ and $L \to C$.
"""
function compositum(K::AnticNumberField, L::AnticNumberField)
  lf = factor(K.pol, L)
  d = degree(first(lf.fac)[1])
  if any(x->degree(x) != d, keys(lf.fac))
    error("2nd field cannot be normal")
  end
  KK = NumberField(first(lf.fac)[1])[1]
  Ka, m1, m2 = absolute_field(KK)
  return Ka, hom(K, Ka, m1(gen(KK))), m2
end

hom(K::AnticNumberField, L::AnticNumberField, a::nf_elem) = NfToNfMor(K, L, a)


