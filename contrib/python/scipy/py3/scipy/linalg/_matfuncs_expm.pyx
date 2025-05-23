# cython: language_level=3
cimport cython
import math
import random
cimport numpy as cnp
import numpy as np
from libc.stdlib cimport malloc, free
from libc.math cimport fabs, ceil, log2, pow
from scipy.linalg.cython_lapack cimport (sgetrf, sgetrs, dgetrf, dgetrs,
                                         cgetrf, cgetrs, zgetrf, zgetrs)
from scipy.linalg.cython_blas cimport (sgemm, saxpy, sscal, scopy, sgemv,
                                       dgemm, daxpy, dscal, dcopy, dgemv,
                                       cgemm, caxpy, cscal, ccopy, cgemv,
                                       zgemm, zaxpy, zscal, zcopy, dgemv,
                                       csscal, zdscal, idamax)

from ._cythonized_array_utils cimport (lapack_t, lapack_cz_t,
        lapack_sd_t, swap_c_and_f_layout)

__all__ = ['pick_pade_structure', 'pade_UV_calc']

# See GH-14813
cnp.import_array()



# ========================= norm1 : s, d, c, z ===============================
# The generic abs() function is made nogil friendly in Cython 3.x (unreleased)
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef double norm1(lapack_t[:, ::1] A):
    """
    Fast 1-norm computation for C-contiguous square arrays.
    Regardless of the dtype we work in double precision to prevent overflows
    """
    cdef Py_ssize_t n = A.shape[0]
    cdef Py_ssize_t i, j
    cdef int ind = 1, intn = <int>n
    cdef double temp = 0.
    cdef double complex temp_cz = 0.
    cdef double temp_sd = 0.
    cdef double *work = <double*> malloc(n*sizeof(double))
    if not work:
        raise MemoryError('Internal function "norm1" failed to allocate memory.')
    try:
        if lapack_t in lapack_cz_t:
            for j in range(n):
                temp_cz = A[0, j]
                work[j] = abs(temp_cz)
            for i in range(1, n):
                for j in range(n):
                    temp_cz = A[i, j]
                    work[j] += abs(temp_cz)
        else:
            for j in range(n):
                temp_sd = A[0, j]
                work[j] = abs(temp_sd)
            for i in range(1, n):
                for j in range(n):
                    temp_sd = A[i, j]
                    work[j] += abs(temp_sd)

        ind = idamax(&intn, &work[0], &ind)
        temp = work[ind-1]
        return temp
    finally:
        free(work)
# ============================================================================

# ========================= kth power norm : d ===============================
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef double kth_power_norm_d(double* A, double* v1, double* v2, Py_ssize_t n, int spins):
    cdef int k, int_one = 1, intn = <int>n
    cdef double one =1., zero = 0.
    for k in range(spins):
        dgemv(<char*>'C', &intn, &intn, &one, &A[0], &intn, &v1[0], &int_one, &zero, &v2[0], &int_one)
        dcopy(&intn, &v2[0], &int_one, &v1[0], &int_one)
    k = idamax(&intn, &v1[0], &int_one)
    return v1[k-1]
# ============================================================================

# ====================== pick_pade_structure : s, d, c, z ====================
@cython.cdivision(True)
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef pick_pade_structure_s(float[:, :, ::1] Am):
    cdef Py_ssize_t n = Am.shape[1], i, j, k
    cdef int lm = 0, s = 0, intn = <int>n, n2= intn*intn, int_one = 1
    cdef float[:, :, ::1] Amv = Am
    cdef:
        float one = 1.0, zero = 0.0
        double normA
        double d4, d6, d8, d10
        double eta0, eta1, eta2, eta3, eta4
        double u = (2.)**(-24.)
        double two_pow_s
        double temp
    cdef double *absA = <double*>malloc(n*n*sizeof(double))
    cdef double *work = <double*>malloc(n*sizeof(double))
    cdef double *work2 = <double*>malloc(n*sizeof(double))
    if not work or not work2 or not absA:
        raise MemoryError('Internal function "pick_pade_structure" failed to allocate memory.')
    cdef double [5] theta
    cdef double [5] coeff
    cdef char* cN = 'N'

    theta[0] = 1.495585217958292e-002
    theta[1] = 2.539398330063230e-001
    theta[2] = 9.504178996162932e-001
    theta[3] = 2.097847961257068e+000
    theta[4] = 4.250000000000000e+000
    coeff[0] = u*100800.
    coeff[1] = u*10059033600.
    coeff[2] = u*4487938430976000.
    coeff[3] = u*5914384781877411840000.
    coeff[4] = u*113250775606021113483283660800000000.
    try:
        for j in range(n):
            work[j] = 1.

        # scopy(&n2, &A[0, 0], &int_one, &Amv[0, 0, 0], &int_one)
        for i in range(n):
            for j in range(n):
                absA[i*n + j] = abs(Am[0, i, j])

        # First spin = normest(|A|, 1), increase m when spun more
        normA = kth_power_norm_d(absA, work, work2, n, 1)
        sgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[0, 0, 0], &intn, &Amv[0, 0, 0], &intn, &zero, &Amv[1, 0, 0], &intn)
        sgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[1, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[2, 0, 0], &intn)
        sgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[3, 0, 0], &intn)
        d4 = norm1(Amv[2]) ** (1./4.)
        d6 = norm1(Amv[3]) ** (1./6.)
        eta0 = max(d4, d6)
        eta1 = eta0

        # m = 3
        temp = kth_power_norm_d(absA, work, work2, n, 6)
        lm = max(<int>ceil(log2(temp/normA/coeff[0])/6), 0)
        if eta0 < theta[0] and lm == 0:
            return 3, s

        # m = 5
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[1])/10), 0)
        if eta1 < theta[1] and lm == 0:
            return 5, s

        # m = 7
        if n < 400:
            sgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d8 = norm1(Amv[4, :, :]) ** (1./8.)
        else:
            d8  = _norm1est(np.asarray(Am[0]), m=8) ** (1./8.)

        eta2 = max(d6, d8)
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[2])/14), 0)
        if eta2 < theta[2] and lm == 0:
            return 7, s

        # m = 9
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[3])/18), 0)
        if eta2 < theta[3] and lm == 0:
            return 9, s

        # m = 13
        # Scale-square
        if n < 400:
            sgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[3, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d10 = norm1(Amv[4, :, :]) ** (1./10.)
        else:
            d10  = _norm1est(np.asarray(Am[0]), m=10) ** (1./10.)

        eta3 = max(d8, d10)
        eta4 = min(eta2, eta3)
        s = max(<int>ceil(log2(eta4/theta[4])), 0)
        if s != 0:
            two_pow_s = 2.** (-s)
            dscal(&n2, &two_pow_s, absA, &int_one)
            # kth_power_norm has spun 19 times already
            two_pow_s = 2.** ((-s)*19.)
            for i in range(n):
                work[i] *= two_pow_s
            normA *= 2.**(-s)
        temp = kth_power_norm_d(absA, work, work2, n, 8)
        s += max(<int>ceil(log2(temp/normA/coeff[4])/26), 0)
        return 13, s
    finally:
        free(work)
        free(work2)
        free(absA)

@cython.cdivision(True)
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef pick_pade_structure_d(double[:, :, ::1] Am):
    cdef Py_ssize_t n = Am.shape[1], i, j, k
    cdef int lm = 0, s = 0, intn = <int>n, n2= intn*intn, int_one = 1
    cdef double[:, :, ::1] Amv = Am
    cdef:
        double one = 1.0, zero = 0.0
        double normA
        double d4, d6, d8, d10
        double eta0, eta1, eta2, eta3, eta4
        double u = (2.)**(-53)
        double two_pow_s
        double temp
    cdef double *absA = <double*>malloc(n*n*sizeof(double))
    cdef double *work = <double*>malloc(n*sizeof(double))
    cdef double *work2 = <double*>malloc(n*sizeof(double))
    if not work or not work2 or not absA:
        raise MemoryError('Internal function "pick_pade_structure" failed to allocate memory.')
    cdef double [5] theta
    cdef double [5] coeff
    cdef char* cN = 'N'

    theta[0] = 1.495585217958292e-002
    theta[1] = 2.539398330063230e-001
    theta[2] = 9.504178996162932e-001
    theta[3] = 2.097847961257068e+000
    theta[4] = 4.250000000000000e+000
    coeff[0] = u*100800.
    coeff[1] = u*10059033600.
    coeff[2] = u*4487938430976000.
    coeff[3] = u*5914384781877411840000.
    coeff[4] = u*113250775606021113483283660800000000.
    try:
        for j in range(n):
            work[j] = 1.

        # dcopy(&n2, &A[0, 0], &int_one, &Amv[0, 0, 0], &int_one)
        for i in range(n):
            for j in range(n):
                absA[i*n + j] = abs(Am[0, i, j])

        # First spin = normest(|A|, 1), increase m when spun more
        normA = kth_power_norm_d(absA, work, work2, n, 1)
        dgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[0, 0, 0], &intn, &Amv[0, 0, 0], &intn, &zero, &Amv[1, 0, 0], &intn)
        dgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[1, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[2, 0, 0], &intn)
        dgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[3, 0, 0], &intn)
        d4 = norm1(Amv[2]) ** (1./4.)
        d6 = norm1(Amv[3]) ** (1./6.)
        eta0 = max(d4, d6)
        eta1 = eta0

        # m = 3
        temp = kth_power_norm_d(absA, work, work2, n, 6)
        lm = max(<int>ceil(log2(temp/normA/coeff[0])/6), 0)
        if eta0 < theta[0] and lm == 0:
            return 3, s

        # m = 5
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[1])/10), 0)
        if eta1 < theta[1] and lm == 0:
            return 5, s

        # m = 7
        if n < 400:
            dgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d8 = norm1(Amv[4, :, :]) ** (1./8.)
        else:
            d8  = _norm1est(np.asarray(Am[0]), m=8) ** (1./8.)

        eta2 = max(d6, d8)
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[2])/14), 0)
        if eta2 < theta[2] and lm == 0:
            return 7, s

        # m = 9
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[3])/18), 0)
        if eta2 < theta[3] and lm == 0:
            return 9, s

        # m = 13
        # Scale-square
        if n < 400:
            dgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[3, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d10 = norm1(Amv[4, :, :]) ** (1./10.)
        else:
            d10  = _norm1est(np.asarray(Am[0]), m=10) ** (1./10.)

        eta3 = max(d8, d10)
        eta4 = min(eta2, eta3)
        s = max(<int>ceil(log2(eta4/theta[4])), 0)
        if s != 0:
            two_pow_s = 2.** (-s)
            dscal(&n2, &two_pow_s, absA, &int_one)
            # kth_power_norm has spun 19 times already
            two_pow_s = 2.** ((-s)*19.)
            for i in range(n):
                work[i] *= two_pow_s
            normA *= 2.**(-s)
        temp = kth_power_norm_d(absA, work, work2, n, 8)
        s += max(<int>ceil(log2(temp/normA/coeff[4])/26), 0)
        return 13, s
    finally:
        free(work)
        free(work2)
        free(absA)

@cython.cdivision(True)
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef pick_pade_structure_c(float complex[:, :, ::1] Am):
    cdef Py_ssize_t n = Am.shape[1], i, j, k
    cdef int lm = 0, s = 0, intn = <int>n, n2= intn*intn, int_one = 1
    cdef float complex[:, :, ::1] Amv = Am
    cdef:
        float complex one = 1.0, zero = 0.0
        double normA
        double d4, d6, d8, d10
        double eta0, eta1, eta2, eta3, eta4
        double u = (2.)**(-24.)
        double two_pow_s
        double temp
    cdef double *absA = <double*>malloc(n*n*sizeof(double))
    cdef double *work = <double*>malloc(n*sizeof(double))
    cdef double *work2 = <double*>malloc(n*sizeof(double))
    if not work or not work2 or not absA:
        raise MemoryError('Internal function "pick_pade_structure" failed to allocate memory.')
    cdef double [5] theta
    cdef double [5] coeff
    cdef char* cN = 'N'

    theta[0] = 1.495585217958292e-002
    theta[1] = 2.539398330063230e-001
    theta[2] = 9.504178996162932e-001
    theta[3] = 2.097847961257068e+000
    theta[4] = 4.250000000000000e+000
    coeff[0] = u*100800.
    coeff[1] = u*10059033600.
    coeff[2] = u*4487938430976000.
    coeff[3] = u*5914384781877411840000.
    coeff[4] = u*113250775606021113483283660800000000.
    try:
        for j in range(n):
            work[j] = 1.

        # ccopy(&n2, &A[0, 0], &int_one, &Amv[0, 0, 0], &int_one)
        for i in range(n):
            for j in range(n):
                absA[i*n + j] = abs(Am[0, i, j])

        # First spin = normest(|A|, 1), increase m when spun more
        normA = kth_power_norm_d(absA, work, work2, n, 1)
        cgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[0, 0, 0], &intn, &Amv[0, 0, 0], &intn, &zero, &Amv[1, 0, 0], &intn)
        cgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[1, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[2, 0, 0], &intn)
        cgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[3, 0, 0], &intn)
        d4 = norm1(Amv[2]) ** (1./4.)
        d6 = norm1(Amv[3]) ** (1./6.)
        eta0 = max(d4, d6)
        eta1 = eta0

        # m = 3
        temp = kth_power_norm_d(absA, work, work2, n, 6)
        lm = max(<int>ceil(log2(temp/normA/coeff[0])/6), 0)
        if eta0 < theta[0] and lm == 0:
            return 3, s

        # m = 5
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[1])/10), 0)
        if eta1 < theta[1] and lm == 0:
            return 5, s

        # m = 7
        if n < 400:
            cgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d8 = norm1(Amv[4, :, :]) ** (1./8.)
        else:
            d8  = _norm1est(np.asarray(Am[0]), m=8) ** (1./8.)

        eta2 = max(d6, d8)
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[2])/14), 0)
        if eta2 < theta[2] and lm == 0:
            return 7, s

        # m = 9
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[3])/18), 0)
        if eta2 < theta[3] and lm == 0:
            return 9, s

        # m = 13
        # Scale-square
        if n < 400:
            cgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[3, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d10 = norm1(Amv[4, :, :]) ** (1./10.)
        else:
            d10  = _norm1est(np.asarray(Am[0]), m=10) ** (1./10.)

        eta3 = max(d8, d10)
        eta4 = min(eta2, eta3)
        s = max(<int>ceil(log2(eta4/theta[4])), 0)
        if s != 0:
            two_pow_s = 2.** (-s)
            dscal(&n2, &two_pow_s, absA, &int_one)
            # kth_power_norm has spun 19 times already
            two_pow_s = 2.** ((-s)*19.)
            for i in range(n):
                work[i] *= two_pow_s
            normA *= 2.**(-s)
        temp = kth_power_norm_d(absA, work, work2, n, 8)
        s += max(<int>ceil(log2(temp/normA/coeff[4])/26), 0)
        return 13, s
    finally:
        free(work)
        free(work2)
        free(absA)

@cython.cdivision(True)
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef pick_pade_structure_z(double complex[:, :, ::1] Am):
    cdef Py_ssize_t n = Am.shape[1], i, j, k
    cdef int lm = 0, s = 0, intn = <int>n, n2= intn*intn, int_one = 1
    cdef double complex[:, :, ::1] Amv = Am
    cdef:
        double complex one = 1.0, zero = 0.0
        double normA
        double d4, d6, d8, d10
        double eta0, eta1, eta2, eta3, eta4
        double u = (2.)**(-53)
        double two_pow_s
        double temp
    cdef double *absA = <double*>malloc(n*n*sizeof(double))
    cdef double *work = <double*>malloc(n*sizeof(double))
    cdef double *work2 = <double*>malloc(n*sizeof(double))
    if not work or not work2 or not absA:
        raise MemoryError('Internal function "pick_pade_structure" failed to allocate memory.')
    cdef double [5] theta
    cdef double [5] coeff
    cdef char* cN = 'N'

    theta[0] = 1.495585217958292e-002
    theta[1] = 2.539398330063230e-001
    theta[2] = 9.504178996162932e-001
    theta[3] = 2.097847961257068e+000
    theta[4] = 4.250000000000000e+000
    coeff[0] = u*100800.
    coeff[1] = u*10059033600.
    coeff[2] = u*4487938430976000.
    coeff[3] = u*5914384781877411840000.
    coeff[4] = u*113250775606021113483283660800000000.
    try:
        for j in range(n):
            work[j] = 1.

        # zcopy(&n2, &A[0, 0], &int_one, &Amv[0, 0, 0], &int_one)
        for i in range(n):
            for j in range(n):
                absA[i*n + j] = abs(Am[0, i, j])

        # First spin = normest(|A|, 1), increase m when spun more
        normA = kth_power_norm_d(absA, work, work2, n, 1)
        zgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[0, 0, 0], &intn, &Amv[0, 0, 0], &intn, &zero, &Amv[1, 0, 0], &intn)
        zgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[1, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[2, 0, 0], &intn)
        zgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[1, 0, 0], &intn, &zero, &Amv[3, 0, 0], &intn)
        d4 = norm1(Amv[2]) ** (1./4.)
        d6 = norm1(Amv[3]) ** (1./6.)
        eta0 = max(d4, d6)
        eta1 = eta0

        # m = 3
        temp = kth_power_norm_d(absA, work, work2, n, 6)
        lm = max(<int>ceil(log2(temp/normA/coeff[0])/6), 0)
        if eta0 < theta[0] and lm == 0:
            return 3, s

        # m = 5
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[1])/10), 0)
        if eta1 < theta[1] and lm == 0:
            return 5, s

        # m = 7
        if n < 400:
            zgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[2, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d8 = norm1(Amv[4, :, :]) ** (1./8.)
        else:
            d8  = _norm1est(np.asarray(Am[0]), m=8) ** (1./8.)

        eta2 = max(d6, d8)
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[2])/14), 0)
        if eta2 < theta[2] and lm == 0:
            return 7, s

        # m = 9
        temp = kth_power_norm_d(absA, work, work2, n, 4)
        lm = max(<int>ceil(log2(temp/normA/coeff[3])/18), 0)
        if eta2 < theta[3] and lm == 0:
            return 9, s

        # m = 13
        # Scale-square
        if n < 400:
            zgemm(cN, cN, &intn, &intn, &intn, &one, &Amv[3, 0, 0], &intn, &Amv[2, 0, 0], &intn, &zero, &Amv[4, 0, 0], &intn)
            d10 = norm1(Amv[4, :, :]) ** (1./10.)
        else:
            d10  = _norm1est(np.asarray(Am[0]), m=10) ** (1./10.)

        eta3 = max(d8, d10)
        eta4 = min(eta2, eta3)
        s = max(<int>ceil(log2(eta4/theta[4])), 0)
        if s != 0:
            two_pow_s = 2.** (-s)
            dscal(&n2, &two_pow_s, absA, &int_one)
            # kth_power_norm has spun 19 times already
            two_pow_s = 2.** ((-s)*19.)
            for i in range(n):
                work[i] *= two_pow_s
            normA *= 2.**(-s)
        temp = kth_power_norm_d(absA, work, work2, n, 8)
        s += max(<int>ceil(log2(temp/normA/coeff[4])/26), 0)
        return 13, s
    finally:
        free(work)
        free(work2)
        free(absA)

# ============================================================================

# ====================== pade_m_UV_calc : s, d, c, z =========================
# Note: MSVC does not accept "Memview[i, j, k] += 1.+0.j" as a valid operation
# and results with error "C2088: '+=': illegal for struct".
# OCD is unbearable but we do explicit addition for that reason.

# Note: gemm calls for A @ B is done via dgemm(.., B, .., A, ..) because arrays
# are in C-contiguous memory layout. This also the reason why getrs has 'T' as
# the argument for TRANSA.
@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_357_UV_calc_s(float[:, :, ::]Am, int n, int m) nogil:
    cdef float b[7]
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef float two=2.0
    cdef float one = 1.0, zero = 0.0, neg_one = -1.0
    if not ipiv:
        raise MemoryError('Internal function "pade_357_UV_calc" failed to allocate memory.')
    try:
        # b[m] is always 1. hence skipped
        if m == 3:
            b[0] = 120.
            b[1] = 60.
            b[2] = 12.
        elif m == 5:
            b[0] = 30240.
            b[1] = 15120.
            b[2] = 3360.
            b[3] = 420.
            b[4] = 30.
        elif m == 7:
            b[0] = 17297280.
            b[1] = 8648640.
            b[2] = 1995840.
            b[3] = 277200.
            b[4] = 25200.
            b[5] = 1512.
            b[6] = 56.
        else:
            raise ValueError(f'Internal function "pade_357_UV_calc" received an invalid value {m}')

        # Utilize the unused powers of Am as scratch memory
        if m == 3:
            # U = Am[0] @ Am[1] + 60.*Am[0]
            scopy(&n2, &Am[0, 0, 0], &int_one, &Am[3, 0, 0], &int_one)
            sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &b[1], &Am[3, 0, 0], &n)
            # V = 12.*Am[1] + 120*I_n
            sscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        elif m == 5:
            # U = Am[0] @ (b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            scopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            sscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            saxpy(&n2, &one, &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)
            # V = b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            sscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            saxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        else:
            # U = Am[0] @ (b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            scopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            sscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            saxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            saxpy(&n2, &one, &Am[3, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            # We ran out of space for dgemm; first compute V and then reuse space for U
            # V = b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            sscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            saxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            saxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]
            # Now we can scratch A[2] or A[3]
            sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        saxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        sgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        sgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info )
        sscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_357_UV_calc_d(double[:, :, ::]Am, int n, int m) nogil:
    cdef double b[7]
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef double two=2.0
    cdef double one = 1.0, zero = 0.0, neg_one = -1.0
    if not ipiv:
        raise MemoryError('Internal function "pade_357_UV_calc" failed to allocate memory.')
    try:
        # b[m] is always 1. hence skipped
        if m == 3:
            b[0] = 120.
            b[1] = 60.
            b[2] = 12.
        elif m == 5:
            b[0] = 30240.
            b[1] = 15120.
            b[2] = 3360.
            b[3] = 420.
            b[4] = 30.
        elif m == 7:
            b[0] = 17297280.
            b[1] = 8648640.
            b[2] = 1995840.
            b[3] = 277200.
            b[4] = 25200.
            b[5] = 1512.
            b[6] = 56.
        else:
            raise ValueError(f'Internal function "pade_357_UV_calc" received an invalid value {m}')

        # Utilize the unused powers of Am as scratch memory
        if m == 3:
            # U = Am[0] @ Am[1] + 60.*Am[0]
            dcopy(&n2, &Am[0, 0, 0], &int_one, &Am[3, 0, 0], &int_one)
            dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &b[1], &Am[3, 0, 0], &n)
            # V = 12.*Am[1] + 120*I_n
            dscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        elif m == 5:
            # U = Am[0] @ (b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            dcopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            dscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            daxpy(&n2, &one, &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)
            # V = b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            dscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            daxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        else:
            # U = Am[0] @ (b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            dcopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            dscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            daxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            daxpy(&n2, &one, &Am[3, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            # We ran out of space for dgemm; first compute V and then reuse space for U
            # V = b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            dscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            daxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            daxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]
            # Now we can scratch A[2] or A[3]
            dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        daxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        dgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        dgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info )
        dscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_357_UV_calc_c(float complex[:, :, ::]Am, int n, int m) nogil:
    cdef float complex b[7]
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef float two=2.0
    cdef float complex one = 1.0, zero = 0.0, neg_one = -1.0
    if not ipiv:
        raise MemoryError('Internal function "pade_357_UV_calc" failed to allocate memory.')
    try:
        # b[m] is always 1. hence skipped
        if m == 3:
            b[0] = 120.
            b[1] = 60.
            b[2] = 12.
        elif m == 5:
            b[0] = 30240.
            b[1] = 15120.
            b[2] = 3360.
            b[3] = 420.
            b[4] = 30.
        elif m == 7:
            b[0] = 17297280.
            b[1] = 8648640.
            b[2] = 1995840.
            b[3] = 277200.
            b[4] = 25200.
            b[5] = 1512.
            b[6] = 56.
        else:
            raise ValueError(f'Internal function "pade_357_UV_calc" received an invalid value {m}')

        # Utilize the unused powers of Am as scratch memory
        if m == 3:
            # U = Am[0] @ Am[1] + 60.*Am[0]
            ccopy(&n2, &Am[0, 0, 0], &int_one, &Am[3, 0, 0], &int_one)
            cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &b[1], &Am[3, 0, 0], &n)
            # V = 12.*Am[1] + 120*I_n
            cscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        elif m == 5:
            # U = Am[0] @ (b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            ccopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            cscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            caxpy(&n2, &one, &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)
            # V = b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            cscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            caxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        else:
            # U = Am[0] @ (b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            ccopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            cscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            caxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            caxpy(&n2, &one, &Am[3, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            # We ran out of space for dgemm; first compute V and then reuse space for U
            # V = b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            cscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            caxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            caxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]
            # Now we can scratch A[2] or A[3]
            cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        caxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        cgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        cgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info )
        csscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_357_UV_calc_z(double complex[:, :, ::]Am, int n, int m) nogil:
    cdef double complex b[7]
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef double two=2.0
    cdef double complex one = 1.0, zero = 0.0, neg_one = -1.0
    if not ipiv:
        raise MemoryError('Internal function "pade_357_UV_calc" failed to allocate memory.')
    try:
        # b[m] is always 1. hence skipped
        if m == 3:
            b[0] = 120.
            b[1] = 60.
            b[2] = 12.
        elif m == 5:
            b[0] = 30240.
            b[1] = 15120.
            b[2] = 3360.
            b[3] = 420.
            b[4] = 30.
        elif m == 7:
            b[0] = 17297280.
            b[1] = 8648640.
            b[2] = 1995840.
            b[3] = 277200.
            b[4] = 25200.
            b[5] = 1512.
            b[6] = 56.
        else:
            raise ValueError(f'Internal function "pade_357_UV_calc" received an invalid value {m}')

        # Utilize the unused powers of Am as scratch memory
        if m == 3:
            # U = Am[0] @ Am[1] + 60.*Am[0]
            zcopy(&n2, &Am[0, 0, 0], &int_one, &Am[3, 0, 0], &int_one)
            zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &b[1], &Am[3, 0, 0], &n)
            # V = 12.*Am[1] + 120*I_n
            zscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        elif m == 5:
            # U = Am[0] @ (b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            zcopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            zscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            zaxpy(&n2, &one, &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)
            # V = b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            zscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            zaxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]

        else:
            # U = Am[0] @ (b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
            zcopy(&n2, &Am[1, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            zscal(&n2, &b[3], &Am[4, 0, 0], &int_one)
            zaxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            zaxpy(&n2, &one, &Am[3, 0, 0], &int_one, &Am[4, 0, 0], &int_one)
            for i in range(n):
                Am[4, i, i] = Am[4, i, i] + b[1]
            # We ran out of space for dgemm; first compute V and then reuse space for U
            # V = b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
            zscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
            zaxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            zaxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
            for i in range(n):
                Am[1, i, i] = Am[1, i, i] + b[0]
            # Now we can scratch A[2] or A[3]
            zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[4, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        zaxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        zgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        zgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info )
        zdscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_9_UV_calc_s(float[:, :, ::]Am, int n) nogil:
    cdef float b[9]
    cdef float *work = <float*>malloc(n*n*sizeof(float))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef float one = 1.0, zero = 0.0, neg_one = -1.0
    cdef float two = 2.0

    if not (work and ipiv):
        raise MemoryError('Internal function "pade_9_UV_calc" failed to allocate memory.')
    try:
        # b[9] = 1. hence skipped
        b[0] = 17643225600.
        b[1] = 8821612800.
        b[2] = 2075673600.
        b[3] = 302702400.
        b[4] = 30270240.
        b[5] = 2162160.
        b[6] = 110880.
        b[7] = 3960.
        b[8] = 90.

        # Utilize the unused powers of Am as scratch memory
        # U = Am[0] @ (b[9]*Am[4] + b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        scopy(&n2, &Am[1, 0, 0], &int_one, &work[0], &int_one)
        sscal(&n2, &b[3], &work[0], &int_one)
        saxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &work[0], &int_one)
        saxpy(&n2, &b[7], &Am[3, 0, 0], &int_one, &work[0], &int_one)
        saxpy(&n2, &one, &Am[4, 0, 0], &int_one, &work[0], &int_one)
        for i in range(n):
            work[i*(n+1)] += b[1]
        # V = b[8]*Am[4] + b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
        sscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
        saxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        saxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        saxpy(&n2, &b[8], &Am[4, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[0]
        # Now we can scratch A[2] or A[3]
        sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work[0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        saxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        sgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        sgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info)
        sscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(work)
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_9_UV_calc_d(double[:, :, ::]Am, int n) nogil:
    cdef double b[9]
    cdef double *work = <double*>malloc(n*n*sizeof(double))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef double one = 1.0, zero = 0.0, neg_one = -1.0
    cdef double two = 2.0

    if not (work and ipiv):
        raise MemoryError('Internal function "pade_9_UV_calc" failed to allocate memory.')
    try:
        # b[9] = 1. hence skipped
        b[0] = 17643225600.
        b[1] = 8821612800.
        b[2] = 2075673600.
        b[3] = 302702400.
        b[4] = 30270240.
        b[5] = 2162160.
        b[6] = 110880.
        b[7] = 3960.
        b[8] = 90.

        # Utilize the unused powers of Am as scratch memory
        # U = Am[0] @ (b[9]*Am[4] + b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        dcopy(&n2, &Am[1, 0, 0], &int_one, &work[0], &int_one)
        dscal(&n2, &b[3], &work[0], &int_one)
        daxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &work[0], &int_one)
        daxpy(&n2, &b[7], &Am[3, 0, 0], &int_one, &work[0], &int_one)
        daxpy(&n2, &one, &Am[4, 0, 0], &int_one, &work[0], &int_one)
        for i in range(n):
            work[i*(n+1)] += b[1]
        # V = b[8]*Am[4] + b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
        dscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
        daxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        daxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        daxpy(&n2, &b[8], &Am[4, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[0]
        # Now we can scratch A[2] or A[3]
        dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work[0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        daxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        dgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        dgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info)
        dscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(work)
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_9_UV_calc_c(float complex[:, :, ::]Am, int n) nogil:
    cdef float complex b[9]
    cdef float complex *work = <float complex*>malloc(n*n*sizeof(float complex))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef float complex one = 1.0, zero = 0.0, neg_one = -1.0
    cdef float two = 2.0

    if not (work and ipiv):
        raise MemoryError('Internal function "pade_9_UV_calc" failed to allocate memory.')
    try:
        # b[9] = 1. hence skipped
        b[0] = 17643225600.
        b[1] = 8821612800.
        b[2] = 2075673600.
        b[3] = 302702400.
        b[4] = 30270240.
        b[5] = 2162160.
        b[6] = 110880.
        b[7] = 3960.
        b[8] = 90.

        # Utilize the unused powers of Am as scratch memory
        # U = Am[0] @ (b[9]*Am[4] + b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        ccopy(&n2, &Am[1, 0, 0], &int_one, &work[0], &int_one)
        cscal(&n2, &b[3], &work[0], &int_one)
        caxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &work[0], &int_one)
        caxpy(&n2, &b[7], &Am[3, 0, 0], &int_one, &work[0], &int_one)
        caxpy(&n2, &one, &Am[4, 0, 0], &int_one, &work[0], &int_one)
        for i in range(n):
            work[i*(n+1)] += b[1]
        # V = b[8]*Am[4] + b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
        cscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
        caxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        caxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        caxpy(&n2, &b[8], &Am[4, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[0]
        # Now we can scratch A[2] or A[3]
        cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work[0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        caxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        cgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        cgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info)
        csscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(work)
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_9_UV_calc_z(double complex[:, :, ::]Am, int n) nogil:
    cdef double complex b[9]
    cdef double complex *work = <double complex*>malloc(n*n*sizeof(double complex))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef int i, info, n2 = n*n, int_one = 1
    cdef double complex one = 1.0, zero = 0.0, neg_one = -1.0
    cdef double two = 2.0

    if not (work and ipiv):
        raise MemoryError('Internal function "pade_9_UV_calc" failed to allocate memory.')
    try:
        # b[9] = 1. hence skipped
        b[0] = 17643225600.
        b[1] = 8821612800.
        b[2] = 2075673600.
        b[3] = 302702400.
        b[4] = 30270240.
        b[5] = 2162160.
        b[6] = 110880.
        b[7] = 3960.
        b[8] = 90.

        # Utilize the unused powers of Am as scratch memory
        # U = Am[0] @ (b[9]*Am[4] + b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        zcopy(&n2, &Am[1, 0, 0], &int_one, &work[0], &int_one)
        zscal(&n2, &b[3], &work[0], &int_one)
        zaxpy(&n2, &b[5], &Am[2, 0, 0], &int_one, &work[0], &int_one)
        zaxpy(&n2, &b[7], &Am[3, 0, 0], &int_one, &work[0], &int_one)
        zaxpy(&n2, &one, &Am[4, 0, 0], &int_one, &work[0], &int_one)
        for i in range(n):
            work[i*(n+1)] += b[1]
        # V = b[8]*Am[4] + b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n
        zscal(&n2, &b[2], &Am[1, 0, 0], &int_one)
        zaxpy(&n2, &b[4], &Am[2, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        zaxpy(&n2, &b[6], &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        zaxpy(&n2, &b[8], &Am[4, 0, 0], &int_one, &Am[1, 0, 0], &int_one)
        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[0]
        # Now we can scratch A[2] or A[3]
        zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work[0], &n, &Am[0, 0, 0], &n, &zero, &Am[3, 0, 0], &n)

        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        zaxpy(&n2, &neg_one, &Am[3, 0, 0], &int_one, &Am[1, 0, 0], &int_one)

        # Convert array layout for solving AX = B into Am[2]
        swap_c_and_f_layout(&Am[3, 0, 0], &Am[2, 0, 0], n, n, n)

        zgetrf( &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &info )
        zgetrs(<char*>'T', &n, &n, &Am[1, 0, 0], &n, &ipiv[0], &Am[2, 0, 0], &n, &info)
        zdscal(&n2, &two, &Am[2, 0, 0], &int_one)
        for i in range(n):
            Am[2, i, i] = Am[2, i, i] + 1.

        # Put it back in Am in C order
        swap_c_and_f_layout(&Am[2, 0, 0], &Am[0, 0, 0], n, n, n)
    finally:
        free(work)
        free(ipiv)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_13_UV_calc_s(float[:, :, ::1]Am, int n) nogil:
    cdef float *work2 = <float*>malloc(n*n*sizeof(float))
    cdef float *work3 = <float*>malloc(n*n*sizeof(float))
    cdef float *work4 = <float*>malloc(n*n*sizeof(float))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef Py_ssize_t i, j, k
    cdef int info, int1 = 1, n2 = n*n
    cdef float one = 1.0, zero = 0.0, neg_one = -1.
    cdef float two = 2.0
    cdef float b[14]
    b[0] = 64764752532480000.
    b[1] = 32382376266240000.
    b[2] = 7771770303897600.
    b[3] = 1187353796428800.
    b[4] = 129060195264000.
    b[5] = 10559470521600.
    b[6] = 670442572800.
    b[7] = 33522128640.
    b[8] = 1323241920.
    b[9] = 40840800.
    b[10] = 960960.
    b[11] = 16380.
    b[12] = 182.
    b[13] = 1.

    if not (work2 and work3 and work4 and ipiv):
        raise MemoryError('Internal function "pade_13_UV_calc" failed to allocate memory.')
    try:
        # U = Am[0] @ (Am[3] @ (b[13]*Am[3] + b[11]*Am[2] + b[9]*Am[1]) +
        #              b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        # V = Am[3] @ (b[12]*Am[3] + b[10]*Am[2] + b[8]*Am[1]) +
        #              b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n

        scopy(&n2, &Am[1, 0, 0], &int1, &work2[0], &int1)
        sscal(&n2, &b[9], &work2[0], &int1)
        saxpy(&n2, &b[11], &Am[2, 0, 0], &int1, &work2[0], &int1)
        saxpy(&n2, &b[13], &Am[3, 0, 0], &int1, &work2[0], &int1)

        scopy(&n2, &Am[1, 0, 0], &int1, &work3[0], &int1)
        sscal(&n2, &b[2], &work3[0], &int1)
        saxpy(&n2, &b[4], &Am[2, 0, 0], &int1, &work3[0], &int1)
        saxpy(&n2, &b[6], &Am[3, 0, 0], &int1, &work3[0], &int1)

        scopy(&n2, &Am[1, 0, 0], &int1, &work4[0], &int1)
        sscal(&n2, &b[8], &work4[0], &int1)
        saxpy(&n2, &b[10], &Am[2, 0, 0], &int1, &work4[0], &int1)
        saxpy(&n2, &b[12], &Am[3, 0, 0], &int1, &work4[0], &int1)

        # Overwrite Am[1] as it is not used further
        sscal(&n2, &b[3], &Am[1, 0, 0], &int1)
        saxpy(&n2, &b[5], &Am[2, 0, 0], &int1, &Am[1, 0, 0], &int1)
        saxpy(&n2, &b[7], &Am[3, 0, 0], &int1, &Am[1, 0, 0], &int1)

        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[1]
            work3[i*(n+1)] += b[0]

        # U = D @ (A @ B + C)
        sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work2[0], &n, &Am[3, 0, 0], &n, &one, &Am[1, 0, 0], &n)
        sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &work2[0], &n)
        # V = A @ B + C
        sgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work4[0], &n, &Am[3, 0, 0], &n, &one, &work3[0], &n)
        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        saxpy(&n2, &neg_one, &work2[0], &int1, &work3[0], &int1)

        # Convert array layout for solving AX = B into work4
        swap_c_and_f_layout(work2, work4, n, n, n)

        sgetrf( &n, &n, &work3[0], &n, &ipiv[0], &info )
        sgetrs(<char*>'T', &n, &n, &work3[0], &n, &ipiv[0], &work4[0], &n, &info )
        sscal(&n2, &two, &work4[0], &int1)
        for i in range(n):
            work4[i*(n+1)] += 1.
        # Put it back in Am in C order
        swap_c_and_f_layout(work4, &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)
        free(work2)
        free(work3)
        free(work4)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_13_UV_calc_d(double[:, :, ::1]Am, int n) nogil:
    cdef double *work2 = <double*>malloc(n*n*sizeof(double))
    cdef double *work3 = <double*>malloc(n*n*sizeof(double))
    cdef double *work4 = <double*>malloc(n*n*sizeof(double))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef Py_ssize_t i, j, k
    cdef int info, int1 = 1, n2 = n*n
    cdef double one = 1.0, zero = 0.0, neg_one = -1.
    cdef double two = 2.0
    cdef double b[14]
    b[0] = 64764752532480000.
    b[1] = 32382376266240000.
    b[2] = 7771770303897600.
    b[3] = 1187353796428800.
    b[4] = 129060195264000.
    b[5] = 10559470521600.
    b[6] = 670442572800.
    b[7] = 33522128640.
    b[8] = 1323241920.
    b[9] = 40840800.
    b[10] = 960960.
    b[11] = 16380.
    b[12] = 182.
    b[13] = 1.

    if not (work2 and work3 and work4 and ipiv):
        raise MemoryError('Internal function "pade_13_UV_calc" failed to allocate memory.')
    try:
        # U = Am[0] @ (Am[3] @ (b[13]*Am[3] + b[11]*Am[2] + b[9]*Am[1]) +
        #              b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        # V = Am[3] @ (b[12]*Am[3] + b[10]*Am[2] + b[8]*Am[1]) +
        #              b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n

        dcopy(&n2, &Am[1, 0, 0], &int1, &work2[0], &int1)
        dscal(&n2, &b[9], &work2[0], &int1)
        daxpy(&n2, &b[11], &Am[2, 0, 0], &int1, &work2[0], &int1)
        daxpy(&n2, &b[13], &Am[3, 0, 0], &int1, &work2[0], &int1)

        dcopy(&n2, &Am[1, 0, 0], &int1, &work3[0], &int1)
        dscal(&n2, &b[2], &work3[0], &int1)
        daxpy(&n2, &b[4], &Am[2, 0, 0], &int1, &work3[0], &int1)
        daxpy(&n2, &b[6], &Am[3, 0, 0], &int1, &work3[0], &int1)

        dcopy(&n2, &Am[1, 0, 0], &int1, &work4[0], &int1)
        dscal(&n2, &b[8], &work4[0], &int1)
        daxpy(&n2, &b[10], &Am[2, 0, 0], &int1, &work4[0], &int1)
        daxpy(&n2, &b[12], &Am[3, 0, 0], &int1, &work4[0], &int1)

        # Overwrite Am[1] as it is not used further
        dscal(&n2, &b[3], &Am[1, 0, 0], &int1)
        daxpy(&n2, &b[5], &Am[2, 0, 0], &int1, &Am[1, 0, 0], &int1)
        daxpy(&n2, &b[7], &Am[3, 0, 0], &int1, &Am[1, 0, 0], &int1)

        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[1]
            work3[i*(n+1)] += b[0]

        # U = D @ (A @ B + C)
        dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work2[0], &n, &Am[3, 0, 0], &n, &one, &Am[1, 0, 0], &n)
        dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &work2[0], &n)
        # V = A @ B + C
        dgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work4[0], &n, &Am[3, 0, 0], &n, &one, &work3[0], &n)
        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        daxpy(&n2, &neg_one, &work2[0], &int1, &work3[0], &int1)

        # Convert array layout for solving AX = B into work4
        swap_c_and_f_layout(work2, work4, n, n, n)

        dgetrf( &n, &n, &work3[0], &n, &ipiv[0], &info )
        dgetrs(<char*>'T', &n, &n, &work3[0], &n, &ipiv[0], &work4[0], &n, &info )
        dscal(&n2, &two, &work4[0], &int1)
        for i in range(n):
            work4[i*(n+1)] += 1.
        # Put it back in Am in C order
        swap_c_and_f_layout(work4, &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)
        free(work2)
        free(work3)
        free(work4)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_13_UV_calc_c(float complex[:, :, ::1]Am, int n) nogil:
    cdef float complex *work2 = <float complex*>malloc(n*n*sizeof(float complex))
    cdef float complex *work3 = <float complex*>malloc(n*n*sizeof(float complex))
    cdef float complex *work4 = <float complex*>malloc(n*n*sizeof(float complex))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef Py_ssize_t i, j, k
    cdef int info, int1 = 1, n2 = n*n
    cdef float complex one = 1.0, zero = 0.0, neg_one = -1.
    cdef float two = 2.0
    cdef float complex b[14]
    b[0] = 64764752532480000.
    b[1] = 32382376266240000.
    b[2] = 7771770303897600.
    b[3] = 1187353796428800.
    b[4] = 129060195264000.
    b[5] = 10559470521600.
    b[6] = 670442572800.
    b[7] = 33522128640.
    b[8] = 1323241920.
    b[9] = 40840800.
    b[10] = 960960.
    b[11] = 16380.
    b[12] = 182.
    b[13] = 1.

    if not (work2 and work3 and work4 and ipiv):
        raise MemoryError('Internal function "pade_13_UV_calc" failed to allocate memory.')
    try:
        # U = Am[0] @ (Am[3] @ (b[13]*Am[3] + b[11]*Am[2] + b[9]*Am[1]) +
        #              b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        # V = Am[3] @ (b[12]*Am[3] + b[10]*Am[2] + b[8]*Am[1]) +
        #              b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n

        ccopy(&n2, &Am[1, 0, 0], &int1, &work2[0], &int1)
        cscal(&n2, &b[9], &work2[0], &int1)
        caxpy(&n2, &b[11], &Am[2, 0, 0], &int1, &work2[0], &int1)
        caxpy(&n2, &b[13], &Am[3, 0, 0], &int1, &work2[0], &int1)

        ccopy(&n2, &Am[1, 0, 0], &int1, &work3[0], &int1)
        cscal(&n2, &b[2], &work3[0], &int1)
        caxpy(&n2, &b[4], &Am[2, 0, 0], &int1, &work3[0], &int1)
        caxpy(&n2, &b[6], &Am[3, 0, 0], &int1, &work3[0], &int1)

        ccopy(&n2, &Am[1, 0, 0], &int1, &work4[0], &int1)
        cscal(&n2, &b[8], &work4[0], &int1)
        caxpy(&n2, &b[10], &Am[2, 0, 0], &int1, &work4[0], &int1)
        caxpy(&n2, &b[12], &Am[3, 0, 0], &int1, &work4[0], &int1)

        # Overwrite Am[1] as it is not used further
        cscal(&n2, &b[3], &Am[1, 0, 0], &int1)
        caxpy(&n2, &b[5], &Am[2, 0, 0], &int1, &Am[1, 0, 0], &int1)
        caxpy(&n2, &b[7], &Am[3, 0, 0], &int1, &Am[1, 0, 0], &int1)

        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[1]
            work3[i*(n+1)] += b[0]

        # U = D @ (A @ B + C)
        cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work2[0], &n, &Am[3, 0, 0], &n, &one, &Am[1, 0, 0], &n)
        cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &work2[0], &n)
        # V = A @ B + C
        cgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work4[0], &n, &Am[3, 0, 0], &n, &one, &work3[0], &n)
        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        caxpy(&n2, &neg_one, &work2[0], &int1, &work3[0], &int1)

        # Convert array layout for solving AX = B into work4
        swap_c_and_f_layout(work2, work4, n, n, n)

        cgetrf( &n, &n, &work3[0], &n, &ipiv[0], &info )
        cgetrs(<char*>'T', &n, &n, &work3[0], &n, &ipiv[0], &work4[0], &n, &info )
        csscal(&n2, &two, &work4[0], &int1)
        for i in range(n):
            work4[i*(n+1)] += 1.
        # Put it back in Am in C order
        swap_c_and_f_layout(work4, &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)
        free(work2)
        free(work3)
        free(work4)

@cython.wraparound(False)
@cython.boundscheck(False)
@cython.initializedcheck(False)
cdef void pade_13_UV_calc_z(double complex[:, :, ::1]Am, int n) nogil:
    cdef double complex *work2 = <double complex*>malloc(n*n*sizeof(double complex))
    cdef double complex *work3 = <double complex*>malloc(n*n*sizeof(double complex))
    cdef double complex *work4 = <double complex*>malloc(n*n*sizeof(double complex))
    cdef int *ipiv = <int*>malloc(n*sizeof(int))
    cdef Py_ssize_t i, j, k
    cdef int info, int1 = 1, n2 = n*n
    cdef double complex one = 1.0, zero = 0.0, neg_one = -1.
    cdef double two = 2.0
    cdef double complex b[14]
    b[0] = 64764752532480000.
    b[1] = 32382376266240000.
    b[2] = 7771770303897600.
    b[3] = 1187353796428800.
    b[4] = 129060195264000.
    b[5] = 10559470521600.
    b[6] = 670442572800.
    b[7] = 33522128640.
    b[8] = 1323241920.
    b[9] = 40840800.
    b[10] = 960960.
    b[11] = 16380.
    b[12] = 182.
    b[13] = 1.

    if not (work2 and work3 and work4 and ipiv):
        raise MemoryError('Internal function "pade_13_UV_calc" failed to allocate memory.')
    try:
        # U = Am[0] @ (Am[3] @ (b[13]*Am[3] + b[11]*Am[2] + b[9]*Am[1]) +
        #              b[7]*Am[3] + b[5]*Am[2] + b[3]*Am[1] + b[1]*I_n)
        # V = Am[3] @ (b[12]*Am[3] + b[10]*Am[2] + b[8]*Am[1]) +
        #              b[6]*Am[3] + b[4]*Am[2] + b[2]*Am[1] + b[0]*I_n

        zcopy(&n2, &Am[1, 0, 0], &int1, &work2[0], &int1)
        zscal(&n2, &b[9], &work2[0], &int1)
        zaxpy(&n2, &b[11], &Am[2, 0, 0], &int1, &work2[0], &int1)
        zaxpy(&n2, &b[13], &Am[3, 0, 0], &int1, &work2[0], &int1)

        zcopy(&n2, &Am[1, 0, 0], &int1, &work3[0], &int1)
        zscal(&n2, &b[2], &work3[0], &int1)
        zaxpy(&n2, &b[4], &Am[2, 0, 0], &int1, &work3[0], &int1)
        zaxpy(&n2, &b[6], &Am[3, 0, 0], &int1, &work3[0], &int1)

        zcopy(&n2, &Am[1, 0, 0], &int1, &work4[0], &int1)
        zscal(&n2, &b[8], &work4[0], &int1)
        zaxpy(&n2, &b[10], &Am[2, 0, 0], &int1, &work4[0], &int1)
        zaxpy(&n2, &b[12], &Am[3, 0, 0], &int1, &work4[0], &int1)

        # Overwrite Am[1] as it is not used further
        zscal(&n2, &b[3], &Am[1, 0, 0], &int1)
        zaxpy(&n2, &b[5], &Am[2, 0, 0], &int1, &Am[1, 0, 0], &int1)
        zaxpy(&n2, &b[7], &Am[3, 0, 0], &int1, &Am[1, 0, 0], &int1)

        for i in range(n):
            Am[1, i, i] = Am[1, i, i] + b[1]
            work3[i*(n+1)] += b[0]

        # U = D @ (A @ B + C)
        zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work2[0], &n, &Am[3, 0, 0], &n, &one, &Am[1, 0, 0], &n)
        zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &Am[1, 0, 0], &n, &Am[0, 0, 0], &n, &zero, &work2[0], &n)
        # V = A @ B + C
        zgemm(<char*>'N', <char*>'N', &n, &n, &n, &one, &work4[0], &n, &Am[3, 0, 0], &n, &one, &work3[0], &n)
        # inv(V-U) (V+U) = inv(V-U) (V-U+2V) = I + 2 inv(V-U) U
        zaxpy(&n2, &neg_one, &work2[0], &int1, &work3[0], &int1)

        # Convert array layout for solving AX = B into work4
        swap_c_and_f_layout(work2, work4, n, n, n)

        zgetrf( &n, &n, &work3[0], &n, &ipiv[0], &info )
        zgetrs(<char*>'T', &n, &n, &work3[0], &n, &ipiv[0], &work4[0], &n, &info )
        zdscal(&n2, &two, &work4[0], &int1)
        for i in range(n):
            work4[i*(n+1)] += 1.
        # Put it back in Am in C order
        swap_c_and_f_layout(work4, &Am[0, 0, 0], n, n, n)
    finally:
        free(ipiv)
        free(work2)
        free(work3)
        free(work4)

# ============================================================================

# ====================== norm1est ============================================

def _norm1est(A, m=1, t=2, max_iter=5):
    """Compute a lower bound for the 1-norm of 2D matrix A or its powers.

    Computing the 1-norm of 8th or 10th power of a very large array is a very
    wasteful computation if we explicitly compute the actual power. The
    estimation exploits (in a nutshell) the following:

        (A @ A @ ... A) @ <thin array> = (A @ (A @ (... @ (A @ <thin array>)))

    And in fact all the rest is practically Ward's power method with ``t``
    starting vectors, hence, thin array and smarter selection of those vectors.

    Thus at some point ``expm`` which uses this function to scale-square, will
    switch to estimating when ``np.abs(A).sum(axis=0).max()`` becomes slower
    than the estimate (``linalg.norm`` is even slower). Currently the switch
    is chosen to be ``n=400``.

    Parameters
    ----------
    A : ndarray
        Input square array of shape (N, N).
    m : int, optional
        If it is different than one, then m-th power of the matrix norm is
        computed.
    t : int, optional
        The number of columns of the internal matrix used in the iterations.
    max_iter : int, optional
        The number of total iterations to be performed. Problems that require
        more than 5 iterations are rarely reported in practice.

    Returns
    -------
    c : float
        The resulting 1-norm condition number estimate of A.

    Notes
    -----
    Implements a SciPy adaptation of Algorithm 2.4 of [1], and the original
    Fortran code given in [2].

    The algorithm involves randomized elements and hence if needed, the seed
    of the Python built-in "random" module can be set for reproducible results.

    References
    ----------
    .. [1] Nicholas J. Higham and Francoise Tisseur (2000), "A Block Algorithm
           for Matrix 1-Norm Estimation, with an Application to 1-Norm
           Pseudospectra." SIAM J. Matrix Anal. Appl. 21(4):1185-1201,
           :doi:`10.1137/S0895479899356080`

    .. [2] Sheung Hun Cheng, Nicholas J. Higham (2001), "Implementation for
           LAPACK of a Block Algorithm for Matrix 1-Norm Estimation",
           NA Report 393

    """
    # We skip parallel col test for complex inputs
    real_A = np.isrealobj(A)
    n = A.shape[0]
    est_old = 0
    ind_hist = []
    S = np.zeros([n, 2*t], dtype=np.int8 if real_A else A.dtype)
    Y = np.empty([n, t], dtype=A.dtype)
    Y[:, 0] = A.sum(axis=1) / n

    # Higham and Tisseur assigns random 1, -1 for initialization but they also
    # mention that it is arbitrary. Hence instead we use e_j to already start
    # the while loop. Also we don't use a temporary X but keep indices instead
    if t > 1:
        cols = random.sample(population=range(n), k=t-1)
        Y[:, 1:t] = A[:, cols]
        ind_hist += cols

    for k in range(max_iter):
        if m >= 1:
            for _ in range(m-1):
                Y = A @ Y

        Y_sums = (np.abs(Y)).sum(axis=0)
        best_j = np.argmax(Y_sums)
        est = Y_sums[best_j]
        if est <= est_old:  # (1)
            est = est_old
            break
        # else:
            # w = Y[:, best_j]
        est_old = est
        S[:, :t] = S[:, t:]
        if real_A:
            S[:, t:] = np.signbit(Y)
        else:
            S[:, t:].fill(1)
            mask = Y != 0.
            S[:, t:][mask] = Y[mask] / np.abs(Y[mask])

        if t > 1 and real_A:
            # (2)
            if ((S[:, t:].T @ S[:, :t]).max(axis=1) == n).all() and k > 0:
                break
            else:
                max_spin = math.ceil(n / t)
                for col in range(t):
                    curr_col = t + col
                    n_it = 0
                    while round(np.abs(S[:, col] @ S[:, :curr_col]).max()) == n:
                        S[:, col] = random.choices([1, -1], k=n)
                        n_it += 1
                        if n_it > max_spin:
                            break

        # (3)
        Z = A.conj().T @ S
        if m >= 1:
            for _ in range(m-1):
                Z = A.conj().T @ Z

        Z_sums = (np.abs(Z)).sum(axis=1)
        if np.argmax(Z_sums) == best_j:  # (4)
            break
        h_sorter = np.argsort(Z_sums)
        if all([x in ind_hist for x in h_sorter[:t]]):  # (5)
            break
        else:
            pick = random.choice(range(n))
            for _ in range(t):
                while pick in ind_hist:
                    pick = random.choice(range(n))
                ind_hist += [pick]

            Y = A[:, ind_hist[-t:]]

    # v = np.zeros_like(X[:, 0])  # just some equal size array
    # v[best_j] = 1

    return est  # , v, w


@cython.initializedcheck(False)
def pade_UV_calc(lapack_t[:, :, ::1]Am, int n, int m):
    """Helper functions for expm to solve the final polynomial evaluation"""
    if lapack_t is float:
        if m in [3, 5, 7]:
            pade_357_UV_calc_s(Am, n, m)
        elif m == 9:
            pade_9_UV_calc_s(Am, n)
        else: 
            pade_13_UV_calc_s(Am, n)
    elif lapack_t is double:
        if m in [3, 5, 7]:
            pade_357_UV_calc_d(Am, n, m)
        elif m == 9:
            pade_9_UV_calc_d(Am, n)
        else: 
            pade_13_UV_calc_d(Am, n)
    elif lapack_t is floatcomplex:
        if m in [3, 5, 7]:
            pade_357_UV_calc_c(Am, n, m)
        elif m == 9:
            pade_9_UV_calc_c(Am, n)
        else: 
            pade_13_UV_calc_c(Am, n)
    elif lapack_t is doublecomplex:
        if m in [3, 5, 7]:
            pade_357_UV_calc_z(Am, n, m)
        elif m == 9:
            pade_9_UV_calc_z(Am, n)
        else: 
            pade_13_UV_calc_z(Am, n)
    else:
        raise ValueError('Internal function "pade_UV_calc" received an unsupported dtype')


@cython.initializedcheck(False)
def pick_pade_structure(lapack_t[:, :, ::1]A):
    """Helper functions for expm to choose Pade approximation order"""
    if lapack_t is float:
        return pick_pade_structure_s(A)
    elif lapack_t is double:
        return pick_pade_structure_d(A)
    elif lapack_t is floatcomplex:
        return pick_pade_structure_c(A)
    elif lapack_t is doublecomplex:
        return pick_pade_structure_z(A)
    else:
        raise ValueError('Internal function "pick_pade_structure" received an unsupported dtype.')
