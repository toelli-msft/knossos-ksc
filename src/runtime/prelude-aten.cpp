
#include "knossos.h"

#include <cmath>

namespace ks {

template <size_t Dim, class T>
tensor<Dim, T>
aten$8$8pow$aT2fi(allocator * alloc, tensor<Dim,T> const& a, int const& i)
{
	return elementwise_map(alloc, a, [i](T const& v) { return std::pow(v, i); });
}

tensor<1, double> 
aten$8$8matmul$aT2fT1f(allocator * alloc, tensor<2,double> const& M, tensor<1,double> const& v)
{
	auto [r,c] = size(M);
    KS_ASSERT(c == size(v));
	tensor<1,double> ret(alloc, r);
	for(int i = 0; i < r; ++i)
		ret[i] = ts_dot(M[i], v);
	return ret;
}

tensor<2, double> 
aten$8$8matmul$aT2fT2f(allocator * alloc, tensor<2,double> const& A, tensor<2,double> const& B)
{
	auto [r,K] = size(A);
	auto [K_,c] = size(B);
  KS_ASSERT(K == K_);
	tensor<2,double> ret(alloc, std::make_tuple(r, c));
	for(int i = 0; i < r; ++i)
		for(int j = 0; j < c; ++j) {
			double tot = 0;
		  for(int k = 0; k < K; ++k)
				tot += A[i][k] * B[k][j];
			ret[i][j] = tot;
		}
	return ret;
}

tuple<tensor<2,double>,tensor<1,double>> 
rev$aten$8$8matmul$a$dT2fT1f$bT1f(allocator * alloc, std::tuple<tensor<2,double>, tensor<1,double>> const& M_v, tensor<1,double> const& dr)
{
  auto [M, v] = M_v;
	auto [r, c] = size(M);
	KS_ASSERT(c == size(v));

	tensor<2,double> retM(alloc, size(M));
	for(int i = 0; i < r; ++i)
		retM[i] = ts_scale(alloc, dr[i], v);

	tensor<1,double> retv(alloc, c);
	for(int i = 0; i < c; ++i) {
		double retvi = 0;
		for(int j = 0; j < r; ++j)
			retvi += M[j][i] * dr[j];
		retv[i] = retvi;
	}

	return std::make_tuple(retM,retv);
}

typedef tensor<2, double> Mat;
/*
(edef aten::cat Mat ((Tensor 1 Mat) Integer))
(edef shape$aten::cat (Tensor 2 (Tuple)) ((Tensor 1 Mat) Integer))
(edef D$aten::cat (LM (Tuple (Tensor 1 Mat) Integer) Mat) ((Tensor 1 Mat) Integer))
(def fwd$aten::cat Mat ((as_i : Tuple (Tensor 1 Mat) Integer) (da : Tuple (Tensor 1 Mat) (Tuple)))
    (let ((as i) as_i)
    (let ((das _) da)
      (aten::cat das i))))
(edef rev$aten::cat (Tuple (Tensor 1 Mat) (Tuple)) ((Tuple (Tensor 1 Mat) Integer) Mat))
(edef shape$rev$aten::cat (Tuple (Tensor 1 (Tensor 2 (Tuple))) (Tuple)) ((Tuple (Tensor 1 Mat) Integer) Mat))
*/
Mat
aten$8$8cat$aT1T2fi(allocator * alloc, tensor<1, Mat> const& As, int dim)
{
	int n = size(As);
	if (n == 0)
		return Mat{};

	if (dim == 1) {
		constexpr int Dim = 1;
		auto sz_out = size(As[0]);
		for(int ai = 1; ai < n; ++ai) {
			auto sz = size(As[ai]);
			KS_ASSERT(get_dimension<1-Dim>(sz_out) == get_dimension<1-Dim>(sz));
			get_dimension<Dim>(sz_out) += get_dimension<Dim>(sz);
		}

		Mat retM(alloc, sz_out);
		
		Mat::index_type offset = {0,0};
		for(int ai = 0; ai < n; ++ai) {
			auto const& A = As[ai];
			auto sz = size(A);
			for(int i = 0; i < get_dimension<0>(sz); ++i)
				for(int j = 0; j < get_dimension<1>(sz); ++j) 
					retM[get_dimension<0>(offset) + i][get_dimension<1>(offset) + j] = A[i][j];
				
			get_dimension<Dim>(offset) += get_dimension<Dim>(sz);
		}

		return retM;
	 }

	 KS_ASSERT(false)
}

tensor<2, tuple<>>
shape$aten$8$8cat$aT1T2fi(allocator * alloc, tensor<1, Mat> const& As, int dim)
{
	 KS_ASSERT(false)
}  

tuple<tensor<1, Mat>,tuple<>>
rev$aten$8$8cat$a$dT1T2fi$bT2f(allocator * alloc, tuple<tensor<1, Mat>, int> const& arg, Mat const& dret)
{
	 KS_ASSERT(false)
}

tuple<tensor<1, tensor<2, tuple<>>>,tuple<>> 
shape$rev$aten$8$8cat$a$dT1T2fi$bT2f(allocator * alloc, tuple<tensor<1, Mat>, int> const& arg, Mat const& dret)
{
	 KS_ASSERT(false)
}


}

