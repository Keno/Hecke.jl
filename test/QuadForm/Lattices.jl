@testset "Lattices" begin
  # Smoke test for genus symbol
  Qx, x = PolynomialRing(FlintQQ, "x")
  K, a = NumberField(x^2 - 2, "a")
  L = quadratic_lattice(K, identity_matrix(K, 10), gram_ambient_space = 35*identity_matrix(K, 10))
  P = prime_decomposition(maximal_order(K), 5)[1][1]
  @test Hecke.genus_symbol(L, P).data == [(10, 1, 1)]

  P = prime_decomposition(maximal_order(K), 2)[1][1]
  GS = Hecke.genus_symbol(L, P)
  @test GS.data[1] == [10]
  @test GS.data[2] == [0]
  @test GS.data[3] == [2]
  @test GS.data[4] == [35]
  @test GS.data[5] == []

  Qx, x = FlintQQ["x"];
  K, a = number_field(x^2 - 2, cached = true);
  Kt, t = K["t"];
  L, b= number_field(t^2 + 11, "b", check = true)
  p = prime_decomposition(maximal_order(K), 2)[1][1]
  P = prime_decomposition(maximal_order(L), p)[1][1]
  H = Hecke.lattice(hermitian_space(K, 2 * identity_matrix(K, 3)), pseudo_matrix(identity_matrix(K, 3), [p, p, p]))
  @test Hecke._genus_symbol(H, fmpz(2)) == Any[(3, 4, true, 4, -64)]
  @test islocally_isometric(H, H, fmpz(2))

  H = Hecke.lattice(hermitian_space(L, L(elem_in_nf(uniformizer(p))) * identity_matrix(L, 3)), pseudo_matrix(identity_matrix(L, 3), [P, P, P]))
  @test Hecke._genus_symbol(H, p) == Any[(3, 3, false)]
  @test islocally_isometric(H, H, p)
end
