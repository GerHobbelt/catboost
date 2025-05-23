# cython: language_level=3


# Expression below is replaced by ``DEF NPY_OLD = True`` for NumPy < 1.19
# and ``DEF NPY_OLD = False`` for NumPy >= 1.19.
DEF NPY_OLD = False


cimport cython
from cpython.object cimport PyObject
cimport numpy as np
IF not NPY_OLD:
    from cpython.pycapsule cimport PyCapsule_IsValid, PyCapsule_GetPointer
    from numpy.random cimport bitgen_t
from scipy._lib.ccallback cimport ccallback_t
from scipy._lib.messagestream cimport MessageStream
from .unuran cimport *
import warnings
import threading
import functools
from collections import namedtuple
import numpy as np
import scipy.stats as stats
from scipy.stats._distn_infrastructure import argsreduce, rv_frozen
from scipy._lib._util import check_random_state
import warnings

np.import_array()

__all__ = ['UNURANError', 'TransformedDensityRejection', 'DiscreteAliasUrn',
           'NumericalInversePolynomial']


cdef extern from "Python.h":
    PyObject *PyErr_Occurred()
    void PyErr_Fetch(PyObject **ptype, PyObject **pvalue, PyObject **ptraceback)
    void PyErr_Restore(PyObject *type, PyObject *value, PyObject *traceback)


# Internal API for handling Python callbacks.
# TODO: Maybe, support ``LowLevelCallable``s in the future?
cdef extern from "unuran_callback.h":
    int init_unuran_callback(ccallback_t *callback, fcn) except -1
    int release_unuran_callback(ccallback_t *callback) except -1

    double pdf_thunk(double x, const unur_distr *distr) nogil
    double dpdf_thunk(double x, const unur_distr *distr) nogil
    double logpdf_thunk(double x, const unur_distr *distr) nogil
    double cont_cdf_thunk(double x, const unur_distr *distr) nogil
    double pmf_thunk(int x, const unur_distr *distr) nogil
    double discr_cdf_thunk(int x, const unur_distr *distr) nogil

    void error_handler(const char *objid, const char *file,
                       int line, const char *errortype,
                       int unur_errno, const char *reason) nogil

# https://stackoverflow.com/questions/5697479/how-can-a-defined-c-value-be-exposed-to-python-in-a-cython-module
cdef extern from "unuran.h":
    cdef double UNUR_INFINITY


class UNURANError(RuntimeError):
    """Raised when an error occurs in the UNU.RAN library."""
    pass


ctypedef double (*URNG_FUNCT)(void *) nogil

IF not NPY_OLD:
    cdef object get_numpy_rng(object seed = None):
        """
        Create a NumPy Generator object from a given seed.

        Parameters
        ----------
        seed : object, optional
            Seed for the generator. If None, no seed is set. The seed can be
            an integer, Generator, or RandomState.

        Returns
        -------
        numpy_rng : object
            An instance of NumPy's Generator class.
        """
        seed = check_random_state(seed)
        if isinstance(seed, np.random.RandomState):
            return np.random.default_rng(seed._bit_generator)
        return seed
ELSE:
    cdef object get_numpy_rng(object seed = None):
        """
        Create a NumPy RandomState object from a given seed. If the seed is
        is an instance of `np.random.Generator`, it is returned as-is.

        Parameters
        ----------
        seed : object, optional
            Seed for the generator. If None, no seed is set. The seed can be
            an integer, Generator, or RandomState.

        Returns
        -------
        numpy_rng : object
            An instance of NumPy's RandomState or Generator class.
        """
        return check_random_state(seed)


@cython.final
cdef class _URNG:
    """
    Build a UNU.RAN's uniform random number generator from a NumPy random
    number generator.

    Parameters
    ----------
    numpy_rng : object
        An instance of NumPy's Generator or RandomState class. i.e. a NumPy
        random number generator.
    """
    cdef object numpy_rng
    cdef double[::1] qrvs_array
    cdef size_t i

    def __init__(self, numpy_rng):
        self.numpy_rng = numpy_rng

    IF NPY_OLD:
        cdef double _next_double(self) nogil:
            with gil:
                return self.numpy_rng.uniform()

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef double _next_qdouble(self) nogil:
        self.i += 1
        return self.qrvs_array[self.i-1]

    cdef unur_urng * get_urng(self) except *:
        """
        Get a ``unur_urng`` object from given ``numpy_rng``.

        Returns
        -------
        unuran_urng : unur_urng *
            A UNU.RAN uniform random number generator.
        """
        cdef unur_urng *unuran_urng
        IF NPY_OLD:
            unuran_urng = unur_urng_new(<URNG_FUNCT>self._next_double,
                                        <void *>self)
            return unuran_urng
        ELSE:
            cdef:
                bitgen_t *numpy_urng
                const char *capsule_name = "BitGenerator"

            capsule = self.numpy_rng.bit_generator.capsule

            if not PyCapsule_IsValid(capsule, capsule_name):
                raise ValueError("Invalid pointer to anon_func_state.")

            numpy_urng = <bitgen_t *> PyCapsule_GetPointer(capsule, capsule_name)
            unuran_urng = unur_urng_new(numpy_urng.next_double,
                                        <void *>(numpy_urng.state))

            return unuran_urng

    cdef unur_urng *get_qurng(self, size, qmc_engine) except *:
        cdef unur_urng *unuran_urng
        self.i = 0
        self.qrvs_array = np.ascontiguousarray(
            qmc_engine.random(size).ravel().astype(np.float64)
        )
        unuran_urng = unur_urng_new(<URNG_FUNCT>self._next_qdouble,
                                    <void *>self)
        return unuran_urng


# Module level lock. This is used to provide thread-safe error reporting.
# UNU.RAN has a thread-unsafe global FILE streams where errors are logged.
# To make it thread-safe, one can aquire a lock before calling
# `unur_set_stream` and release once the stream is not needed anymore.
cdef object _lock = threading.RLock()

cdef:
    unur_urng *default_urng
    object default_numpy_rng
    _URNG _urng_builder


cdef object _setup_unuran():
    """
    Sets the default UNU.RAN uniform random number generator and error
    handler.
    """
    global default_urng
    global default_numpy_rng
    global _urng_builder

    default_numpy_rng = get_numpy_rng()

    cdef MessageStream _messages = MessageStream()

    _lock.acquire()
    try:
        unur_set_stream(_messages.handle)
        # try to set a default URNG.
        try:
            _urng_builder = _URNG(default_numpy_rng)
            default_urng = _urng_builder.get_urng()
            if default_urng == NULL:
                raise UNURANError(_messages.get())
        except Exception as e:
            msg = "Failed to initialize the default URNG."
            raise RuntimeError(msg) from e
    finally:
        _lock.release()

    unur_set_default_urng(default_urng)
    unur_set_error_handler(error_handler)


_setup_unuran()


cdef dict _unpack_dist(object dist, str dist_type, list meths = None,
                       list optional_meths = None):
    """
    Get the required methods/attributes from a Python class or object.

    Parameters
    ----------
    dist : object
        An instance of a Python class or an object with required methods.
    dist_type : str
        Type of the distribution. "cont" for continuous distribution
        and "discr" for discrete distribution.
    meths : list
        A list of methods to get from `dist`.
    optional_meths : list, optional
        A list of optional methods to be returned if found. No error
        is raised if some of the methods in this list are not found.

    Returns
    -------
    callbacks : dict
        A dictionary of callbacks (methods found).

    Raises
    ------
    ValueError
        A ValueError is raised in case some methods in the `meths` list
        are not found.
    """
    cdef dict callbacks = {}
    if isinstance(dist, rv_frozen):
        if isinstance(dist.dist, stats.rv_continuous):
            class wrap_dist:
                def __init__(self, dist):
                    self.dist = dist
                    (self.args, self.loc,
                     self.scale) = dist.dist._parse_args(*dist.args,
                                                         **dist.kwds)
                    self.support = dist.support
                def pdf(self, x):
                    # some distributions require array inputs.
                    x = np.atleast_1d((x-self.loc)/self.scale)
                    return max(0, self.dist.dist._pdf(x, *self.args)/self.scale)
                def logpdf(self, x):
                    # some distributions require array inputs.
                    x = np.asarray((x-self.loc)/self.scale)
                    if self.pdf(x) > 0:
                        return self.dist.dist._logpdf(x, *self.args) - np.log(self.scale)
                    return -np.inf
                def cdf(self, x):
                    x = np.atleast_1d((x-self.loc)/self.scale)
                    res = self.dist.dist._cdf(x, *self.args)
                    if res < 0:
                        return 0
                    elif res > 1:
                        return 1
                    return res
        elif isinstance(dist.dist, stats.rv_discrete):
            class wrap_dist:
                def __init__(self, dist):
                    self.dist = dist
                    (self.args, self.loc,
                     _) = dist.dist._parse_args(*dist.args,
                                                **dist.kwds)
                    self.support = dist.support
                def pmf(self, x):
                    # some distributions require array inputs.
                    x = np.atleast_1d(x-self.loc)
                    return max(0, self.dist.dist._pmf(x, *self.args))
                def cdf(self, x):
                    x = np.atleast_1d(x-self.loc)
                    res = self.dist.dist._cdf(x, *self.args)
                    if res < 0:
                        return 0
                    elif res > 1:
                        return 1
                    return res
        dist = wrap_dist(dist)
    if meths is not None:
        for meth in meths:
            if hasattr(dist, meth):
                callbacks[meth] = getattr(dist, meth)
            else:
                msg = f"`{meth}` required but not found."
                raise ValueError(msg)
    if optional_meths is not None:
        for meth in optional_meths:
            if hasattr(dist, meth):
                callbacks[meth] = getattr(dist, meth)
    return callbacks


cdef void _pack_distr(unur_distr *distr, dict callbacks) except *:
    """
    Set the methods of a continuous or discrete distribution object
    using a dictionary of callbacks.

    Parameters
    ----------
    distr : unur_distr *
        A continuous or discrete distribution object.
    callbacks : dict
        A dictionary of callbacks.
    """
    if unur_distr_is_cont(distr):
        if "pdf" in callbacks:
            unur_distr_cont_set_pdf(distr, pdf_thunk)
        if "dpdf" in callbacks:
            unur_distr_cont_set_dpdf(distr, dpdf_thunk)
        if "cdf" in callbacks:
            unur_distr_cont_set_cdf(distr, cont_cdf_thunk)
        if "logpdf" in callbacks:
            unur_distr_cont_set_logpdf(distr, logpdf_thunk)
    else:
        if "pmf" in callbacks:
            unur_distr_discr_set_pmf(distr, pmf_thunk)
        if "cdf" in callbacks:
            unur_distr_discr_set_cdf(distr, discr_cdf_thunk)


def _validate_domain(domain, dist):
    if domain is None and hasattr(dist, 'support'):
        # if the distribution has a support method, use it
        # to get the domain.
        domain = dist.support()
    if domain is not None:
        # UNU.RAN doesn't recognize nans in the probability vector
        # and throws an "unknown error". Hence, check for nans ourselves
        if np.isnan(domain).any():
            raise ValueError("`domain` must contain only non-nan values.")
        # Length of the domain must be exactly 2.
        if len(domain) != 2:
            raise ValueError("`domain` must be a length 2 tuple.")
        # Throw an error here if it can't be converted into a tuple.
        domain = tuple(domain)
    return domain


cdef double[::1] _validate_pv(pv) except *:
    cdef double[::1] pv_view = None
    if pv is not None:
        # Make sure the PV is a contiguous array of doubles.
        pv = pv_view = np.ascontiguousarray(pv, dtype=np.float64)
        # Empty arrays not allowed.
        if pv.size == 0:
            raise ValueError("probability vector must contain at least "
                             "one element.")
        # NaNs and infs not recognized by UNU.RAN so throw an error here
        # only.
        if not np.isfinite(pv).all():
            raise ValueError("probability vector must contain only "
                             "finite / non-nan values.")
        # This special case is not handled by UNU.RAN and it just throws
        # an "unknown error".
        if (pv == 0).all():
            raise ValueError("probability vector must contain at least "
                             "one non-zero value.")
    # return a contiguous memory view of the PV
    return pv_view


def _validate_qmc_input(qmc_engine, d):
    # Input validation for `qmc_engine` and `d`
    # Error messages for invalid `d` are raised by QMCEngine
    # we could probably use a stats.qmc.check_qrandom_state
    if isinstance(qmc_engine, stats.qmc.QMCEngine):
        if d is not None and qmc_engine.d != d:
            message = "`d` must be consistent with dimension of `qmc_engine`."
            raise ValueError(message)
        d = qmc_engine.d if d is None else d
    elif qmc_engine is None:
        d = 1 if d is None else d
        qmc_engine = stats.qmc.Halton(d)
    else:
        message = ("`qmc_engine` must be an instance of "
                    "`scipy.stats.qmc.QMCEngine` or `None`.")
        raise ValueError(message)

    return qmc_engine, d


cdef class Method:
    """
    A base class for all the wrapped generators.

    There are 6 basic functions of this base class:

    * It provides a `_set_rng` method to initialize and set a `unur_gen`
      object. It should be called during the setup stage in the `__cinit__`
      method. As it uses MessageStream, the call must be protected under
      the module-level lock.
    * `_check_errorcode` must be called after calling a UNU.RAN function
      that returns a error code. It raises an error if an error has
      occurred in UNU.RAN.
    * It implements the `rvs` public method for sampling. No child class
      should override this method.
    * Provides a `set_random_state` method to change the seed.
    * Implements the __dealloc__ method. The child class must not overide
      this method.
    * Implements __reduce__ method to allow pickling.

    """
    cdef unur_distr *distr
    cdef unur_par *par
    cdef unur_gen *rng
    cdef unur_urng *urng
    cdef object numpy_rng
    cdef _URNG _urng_builder
    cdef object callbacks
    cdef object _callback_wrapper
    cdef MessageStream _messages
    # save all the arguments to enable pickling
    cdef object _kwargs

    cdef inline void _check_errorcode(self, int errorcode) except *:
        # check for non-zero errorcode
        if errorcode != UNUR_SUCCESS:
            msg = self._messages.get()
            # the message must be non-empty whenever an error occurs in UNU.RAN.
            # if the message is empty, means a warning was raised.
            if msg:
                raise UNURANError(msg)

    cdef inline void _set_rng(self, object random_state) except *:
        """
        Create a UNU.RAN random number generator.

        Parameters
        ----------
        random_state : object
            Seed for the uniform random number generator. Can be a integer,
            Generator, or RandomState.
        """
        cdef ccallback_t callback
        self.numpy_rng = get_numpy_rng(random_state)
        self._urng_builder = _URNG(self.numpy_rng)
        self.urng = self._urng_builder.get_urng()
        if self.urng == NULL:
            raise UNURANError(self._messages.get())
        self._check_errorcode(unur_set_urng(self.par, self.urng))
        has_callback_wrapper = (self._callback_wrapper is not None)
        try:
            if has_callback_wrapper:
                init_unuran_callback(&callback, self._callback_wrapper)
            self.rng = unur_init(self.par)
            # set self.par = NULL because a call to `unur_init` destroys
            # the parameter object. See "Creating a generator object" in
            # http://statmath.wu.ac.at/software/unuran/doc/unuran.html#Concepts
            self.par = NULL
            if self.rng == NULL:
                if PyErr_Occurred():
                    return
                raise UNURANError(self._messages.get())
            unur_distr_free(self.distr)
            self.distr = NULL
        finally:
            if has_callback_wrapper:
                release_unuran_callback(&callback)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _rvs_cont(self, double[::1] out) except *:
        """
        Sample random variates from a continuous distribution.

        Parameters
        ----------
        out : double[::1]
            A memory view of size ``size`` to store the result.
        """
        cdef:
            ccallback_t callback
            unur_gen *rng = self.rng
            size_t i
            size_t size = len(out)
            PyObject *type
            PyObject *value
            PyObject *traceback

        has_callback_wrapper = (self._callback_wrapper is not None)
        error = 0

        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)

            if has_callback_wrapper:
                init_unuran_callback(&callback, self._callback_wrapper)
            for i in range(size):
                out[i] = unur_sample_cont(rng)
                if PyErr_Occurred():
                    error = 1
                    return
            msg = self._messages.get()
            if msg:
                raise UNURANError(msg)
        finally:
            if error:
                PyErr_Fetch(&type, &value, &traceback)
            _lock.release()
            if error:
                PyErr_Restore(type, value, traceback)
            if has_callback_wrapper:
                release_unuran_callback(&callback)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _rvs_discr(self, int[::1] out) except *:
        """
        Sample random variates from a discrete distribution.

        Parameters
        ----------
        out : int[::1]
            A memory view of size ``size`` to store the result.
        """
        cdef:
            ccallback_t callback
            unur_gen *rng = self.rng
            size_t i
            size_t size = len(out)
            PyObject *type
            PyObject *value
            PyObject *traceback

        has_callback_wrapper = (self._callback_wrapper is not None)
        error = 0

        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)

            if has_callback_wrapper:
                init_unuran_callback(&callback, self._callback_wrapper)
            for i in range(size):
                out[i] = unur_sample_discr(rng)
                if PyErr_Occurred():
                    error = 1
                    return
            msg = self._messages.get()
            if msg:
                raise UNURANError(msg)
        finally:
            if error:
                PyErr_Fetch(&type, &value, &traceback)
            _lock.release()
            if error:
                PyErr_Restore(type, value, traceback)
            if has_callback_wrapper:
                release_unuran_callback(&callback)

    def rvs(self, size=None, random_state=None):
        """
        rvs(size=None, random_state=None)

        Sample from the distribution.

        Parameters
        ----------
        size : int or tuple, optional
            The shape of samples. Default is ``None`` in which case a scalar
            sample is returned.
        random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

            A NumPy random number generator or seed for the underlying NumPy random
            number generator used to generate the stream of uniform random numbers.
            If `random_state` is None (or `np.random`), `random_state` provided during
            initialization is used.
            If `random_state` is an int, a new ``RandomState`` instance is used,
            seeded with `random_state`.
            If `random_state` is already a ``Generator`` or ``RandomState`` instance then
            that instance is used.

        Returns
        -------
        rvs : array_like
            A NumPy array of random variates.
        """
        cdef double[::1] out_cont
        cdef int[::1] out_discr
        N = 1 if size is None else np.prod(size)
        prev_random_state = self.numpy_rng
        if random_state is not None:
            self.set_random_state(random_state)
        if unur_distr_is_cont(unur_get_distr(self.rng)):
            out_cont = np.empty(N, dtype=np.float64)
            self._rvs_cont(out_cont)
            if random_state is not None:
                self.set_random_state(prev_random_state)
            if size is None:
                return out_cont[0]
            return np.asarray(out_cont).reshape(size)
        elif unur_distr_is_discr(unur_get_distr(self.rng)):
            out_discr = np.empty(N, dtype=np.int32)
            self._rvs_discr(out_discr)
            if random_state is not None:
                self.set_random_state(prev_random_state)
            if size is None:
                return out_discr[0]
            return np.asarray(out_discr).reshape(size)
        else:
            raise NotImplementedError("only univariate continuous and "
                                      "discrete distributions supported")

    def set_random_state(self, random_state=None):
        """
        set_random_state(random_state=None)

        Set the underlying uniform random number generator.

        Parameters
        ----------
        random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

            A NumPy random number generator or seed for the underlying NumPy random
            number generator used to generate the stream of uniform random numbers.
            If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
            singleton is used.
            If `random_state` is an int, a new ``RandomState`` instance is used,
            seeded with `random_state`.
            If `random_state` is already a ``Generator`` or ``RandomState`` instance then
            that instance is used.
        """
        self.numpy_rng = get_numpy_rng(random_state)
        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)
            unur_urng_free(self.urng)
            self._urng_builder = _URNG(self.numpy_rng)
            self.urng = self._urng_builder.get_urng()
            if self.urng == NULL:
                raise UNURANError(self._messages.get())
            unur_chg_urng(self.rng, self.urng)
        finally:
            _lock.release()

    @cython.final
    def __dealloc__(self):
        if self.distr != NULL:
            unur_distr_free(self.distr)
            self.distr = NULL
        if self.par != NULL:
            unur_par_free(self.par)
            self.par = NULL
        if self.rng != NULL:
            unur_free(self.rng)
            self.rng = NULL
        if self.urng != NULL:
            unur_urng_free(self.urng)
            self.urng = NULL

    # Pickling support
    @cython.final
    def __reduce__(self):
        klass = functools.partial(self.__class__, **self._kwargs)
        return (klass, ())


cdef class TransformedDensityRejection(Method):
    r"""
    TransformedDensityRejection(dist, *, mode=None, center=None, domain=None, c=-0.5, construction_points=30, use_dars=True, max_squeeze_hat_ratio=0.99, random_state=None)

    Transformed Density Rejection (TDR) Method.

    TDR is an acceptance/rejection method that uses the concavity of a
    transformed density to construct hat function and squeezes automatically.
    Most universal algorithms are very slow compared to algorithms that are
    specialized to that distribution. Algorithms that are fast have a slow
    setup and require large tables. The aim of this universal method is to
    provide an algorithm that is not too slow and needs only a short setup.
    This method can be applied to univariate and unimodal continuous
    distributions with T-concave density function. See [1]_ and [2]_ for
    more details.

    Parameters
    ----------
    dist : object
        An instance of a class with ``pdf`` and ``dpdf`` methods.

        * ``pdf``: PDF of the distribution. The signature of the PDF is
          expected to be: ``def pdf(self, x: float) -> float``. i.e.
          the PDF should accept a Python float and
          return a Python float. It doesn't need to integrate to 1 i.e.
          the PDF doesn't need to be normalized.
        * ``dpdf``: Derivative of the PDF w.r.t x (i.e. the variate). Must
          have the same signature as the PDF.

    mode : float, optional
        (Exact) Mode of the distribution. Default is ``None``.
    center : float, optional
        Approximate location of the mode or the mean of the distribution.
        This location provides some information about the main part of the
        PDF and is used to avoid numerical problems. Default is ``None``.
    domain : list or tuple of length 2, optional
        The support of the distribution.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise the support is assumed to be :math:`(-\infty, \infty)`.

    c : {-0.5, 0.}, optional
        Set parameter ``c`` for the transformation function ``T``. The
        default is -0.5. The transformation of the PDF must be concave in
        order to construct the hat function. Such a PDF is called T-concave.
        Currently the following transformations are supported:

        .. math::

            c = 0.: T(x) &= \log(x)\\
            c = -0.5: T(x) &= \frac{1}{\sqrt{x}} \text{ (Default)}

    construction_points : int or array_like, optional
        If an integer, it defines the number of construction points. If it
        is array-like, the elements of the array are used as construction
        points. Default is 30.
    use_dars : bool, optional
        If True, "derandomized adaptive rejection sampling" (DARS) is used
        in setup. See [1]_ for the details of the DARS algorithm. Default
        is True.
    max_squeeze_hat_ratio : float, optional
        Set upper bound for the ratio (area below squeeze) / (area below hat).
        It must be a number between 0 and 1. Default is 0.99.
    random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    References
    ----------
    .. [1] UNU.RAN reference manual, Section 5.3.16,
           "TDR - Transformed Density Rejection",
           http://statmath.wu.ac.at/software/unuran/doc/unuran.html#TDR
    .. [2] Hörmann, Wolfgang. "A rejection technique for sampling from
           T-concave distributions." ACM Transactions on Mathematical
           Software (TOMS) 21.2 (1995): 182-193
    .. [3] W.R. Gilks and P. Wild (1992). Adaptive rejection sampling for
           Gibbs sampling, Applied Statistics 41, pp. 337-348.

    Examples
    --------
    >>> from scipy.stats.sampling import TransformedDensityRejection
    >>> import numpy as np

    Suppose we have a density:

    .. math::

        f(x) = \begin{cases}
                1 - x^2,  &  -1 \leq x \leq 1 \\
                0,        &  \text{otherwise}
               \end{cases}

    The derivative of this density function is:

    .. math::

        \frac{df(x)}{dx} = \begin{cases}
                            -2x,  &  -1 \leq x \leq 1 \\
                            0,    &  \text{otherwise}
                           \end{cases}

    Notice that the PDF doesn't integrate to 1. As this is a rejection based
    method, we need not have a normalized PDF. To initialize the generator,
    we can use:

    >>> urng = np.random.default_rng()
    >>> class MyDist:
    ...     def pdf(self, x):
    ...         return 1-x*x
    ...     def dpdf(self, x):
    ...         return -2*x
    ...
    >>> dist = MyDist()
    >>> rng = TransformedDensityRejection(dist, domain=(-1, 1),
    ...                                   random_state=urng)

    Domain can be very useful to truncate the distribution but to avoid passing
    it everytime to the constructor, a default domain can be set by providing a
    `support` method in the distribution object (`dist`):

    >>> class MyDist:
    ...     def pdf(self, x):
    ...         return 1-x*x
    ...     def dpdf(self, x):
    ...         return -2*x
    ...     def support(self):
    ...         return (-1, 1)
    ...
    >>> dist = MyDist()
    >>> rng = TransformedDensityRejection(dist, random_state=urng)

    Now, we can use the `rvs` method to generate samples from the distribution:

    >>> rvs = rng.rvs(1000)

    We can check that the samples are from the given distribution by visualizing
    its histogram:

    >>> import matplotlib.pyplot as plt
    >>> x = np.linspace(-1, 1, 1000)
    >>> fx = 3/4 * dist.pdf(x)  # 3/4 is the normalizing constant
    >>> plt.plot(x, fx, 'r-', lw=2, label='true distribution')
    >>> plt.hist(rvs, bins=20, density=True, alpha=0.8, label='random variates')
    >>> plt.xlabel('x')
    >>> plt.ylabel('PDF(x)')
    >>> plt.title('Transformed Density Rejection Samples')
    >>> plt.legend()
    >>> plt.show()
    """
    cdef double[::1] construction_points_array

    def __cinit__(self,
                  dist,
                  *,
                  mode=None,
                  center=None,
                  domain=None,
                  c=-0.5,
                  construction_points=30,
                  use_dars=True,
                  max_squeeze_hat_ratio=0.99,
                  random_state=None):
        (domain, c, construction_points) = self._validate_args(dist, domain, c, construction_points)

        # save all the arguments for pickling support
        self._kwargs = {
            'dist': dist,
            'mode': mode,
            'center': center,
            'domain': domain,
            'c': c,
            'construction_points': construction_points,
            'use_dars': use_dars,
            'max_squeeze_hat_ratio': max_squeeze_hat_ratio,
            'random_state': random_state
        }

        cdef:
            unur_distr *distr
            unur_par *par
            unur_gen *rng

        self.callbacks = _unpack_dist(dist, "cont", meths=["pdf", "dpdf"])
        def _callback_wrapper(x, name):
            return self.callbacks[name](x)
        self._callback_wrapper = _callback_wrapper
        self._messages = MessageStream()
        _lock.acquire()
        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_cont_new()
            if self.distr == NULL:
                raise UNURANError(self._messages.get())
            _pack_distr(self.distr, self.callbacks)

            if domain is not None:
                self._check_errorcode(unur_distr_cont_set_domain(self.distr, domain[0],
                                                                 domain[1]))

            if mode is not None:
                self._check_errorcode(unur_distr_cont_set_mode(self.distr, mode))
            if center is not None:
                self._check_errorcode(unur_distr_cont_set_center(self.distr, center))

            self.par = unur_tdr_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())
            self._check_errorcode(unur_tdr_set_c(self.par, c))
            if self.construction_points_array is None:
                self._check_errorcode(unur_tdr_set_cpoints(self.par, construction_points, NULL))
            else:
                self._check_errorcode(unur_tdr_set_cpoints(self.par, len(self.construction_points_array),
                                                           &self.construction_points_array[0]))

            # PS variant is the default in UNU.RAN
            self._check_errorcode(unur_tdr_set_variant_ps(self.par))

            self._check_errorcode(unur_tdr_set_usedars(self.par, use_dars))
            self._check_errorcode(unur_tdr_set_max_sqhratio(self.par, max_squeeze_hat_ratio))
            # the parameter max_intervals is not part of the SciPy API
            # UNU.RAN default is 100, we use a higher value to avoid problems
            # if max_squeeze_hat_ratio is increased
            self._check_errorcode(unur_tdr_set_max_intervals(self.par, 10000))

            self._set_rng(random_state)
        finally:
            _lock.release()

    cdef object _validate_args(self, dist, domain, c, construction_points):
        domain = _validate_domain(domain, dist)
        if c not in {-0.5, 0.}:
            raise ValueError("`c` must either be -0.5 or 0.")
        if not np.isscalar(construction_points):
            self.construction_points_array = np.ascontiguousarray(construction_points,
                                                                  dtype=np.float64)
            if len(self.construction_points_array) == 0:
                raise ValueError("`construction_points` must either be a scalar or a "
                                 "non-empty array.")
        else:
            self.construction_points_array = None
            if (construction_points <= 0 or
                construction_points != int(construction_points)):
                raise ValueError("`construction_points` must be a positive integer.")

        return domain, c, construction_points

    @property
    def squeeze_hat_ratio(self):
        """
        Get the current ratio (area below squeeze) / (area below hat) for the
        generator.
        """
        return unur_tdr_get_sqhratio(self.rng)

    @property
    def hat_area(self):
        """Get the area below the hat for the generator."""
        return unur_tdr_get_hatarea(self.rng)

    @property
    def squeeze_area(self):
        """Get the area below the squeeze for the generator."""
        return unur_tdr_get_squeezearea(self.rng)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _ppf_hat(self, const double *u, double *out, size_t N) except *:
        cdef:
            size_t i
        for i in range(N):
            out[i] = unur_tdr_eval_invcdfhat(self.rng, u[i], NULL, NULL, NULL)

    def ppf_hat(self, u):
        """
        ppf_hat(u)

        Evaluate the inverse of the CDF of the hat distribution at `u`.

        Parameters
        ----------
        u : array_like
            An array of percentiles

        Returns
        -------
        ppf_hat : array_like
            Array of quantiles corresponding to the given percentiles.

        Examples
        --------
        >>> from scipy.stats.sampling import TransformedDensityRejection
        >>> from scipy.stats import norm
        >>> import numpy as np
        >>> from math import exp
        >>>
        >>> class MyDist:
        ...     def pdf(self, x):
        ...         return exp(-0.5 * x**2)
        ...     def dpdf(self, x):
        ...         return -x * exp(-0.5 * x**2)
        ...
        >>> dist = MyDist()
        >>> rng = TransformedDensityRejection(dist)
        >>>
        >>> rng.ppf_hat(0.5)
        -0.00018050266342393984
        >>> norm.ppf(0.5)
        0.0
        >>> u = np.linspace(0, 1, num=1000)
        >>> ppf_hat = rng.ppf_hat(u)
        """
        u = np.asarray(u, dtype='d')
        oshape = u.shape
        u = u.ravel()
        # UNU.RAN fills in ends of the support when u < 0 or u > 1 while
        # SciPy fills in nans. Prefer SciPy behaviour.
        cond0 = 0 <= u
        cond1 = u <= 1
        cond2 = cond0 & cond1
        goodu = argsreduce(cond2, u)[0]
        out = np.empty_like(u)
        cdef double[::1] u_view = np.ascontiguousarray(goodu)
        cdef double[::1] goodout = np.empty_like(u_view)
        if cond2.any():
            self._ppf_hat(&u_view[0], &goodout[0], len(goodu))
        np.place(out, cond2, goodout)
        np.place(out, ~cond2, np.nan)
        return np.asarray(out).reshape(oshape)[()]


cdef class SimpleRatioUniforms(Method):
    r"""
    SimpleRatioUniforms(dist, *, mode=None, pdf_area=1, domain=None, cdf_at_mode=None, random_state=None)

    Simple Ratio-of-Uniforms (SROU) Method.

    SROU is based on the ratio-of-uniforms method that uses universal inequalities for
    constructing a (universal) bounding rectangle. It works for T-concave distributions
    with ``T(x) = -1/sqrt(x)``. The main advantage of the method is a fast setup. This
    can be beneficial if one repeatedly needs to generate small to moderate samples of
    a distribution with different shape parameters. In such a situation, the setup step of
    `NumericalInverseHermite` or `NumericalInversePolynomial` will lead to poor performance.

    Parameters
    ----------
    dist : object
        An instance of a class with ``pdf`` method.

        * ``pdf``: PDF of the distribution. The signature of the PDF is
          expected to be: ``def pdf(self, x: float) -> float``. i.e.
          the PDF should accept a Python float and
          return a Python float. It doesn't need to integrate to 1 i.e.
          the PDF doesn't need to be normalized. If not normalized, `pdf_area`
          should be set to the area under the PDF.

    mode : float, optional
        (Exact) Mode of the distribution. When the mode is ``None``, a slow
        numerical routine is used to approximate it. Default is ``None``.
    pdf_area : float, optional
        Area under the PDF. Optionally, an upper bound to the area under
        the PDF can be passed at the cost of increased rejection constant.
        Default is 1.
    domain : list or tuple of length 2, optional
        The support of the distribution.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise the support is assumed to be :math:`(-\infty, \infty)`.

    cdf_at_mode : float, optional
        CDF at the mode. It can be given to increase the performance of the
        algorithm. The rejection constant is halfed when CDF at mode is given.
        Default is ``None``.
    random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    References
    ----------
    .. [1] UNU.RAN reference manual, Section 5.3.16,
           "SROU - Simple Ratio-of-Uniforms method",
           http://statmath.wu.ac.at/software/unuran/doc/unuran.html#SROU
    .. [2] Leydold, Josef. "A simple universal generator for continuous and
           discrete univariate T-concave distributions." ACM Transactions on
           Mathematical Software (TOMS) 27.1 (2001): 66-82
    .. [3] Leydold, Josef. "Short universal generators via generalized ratio-of-uniforms
           method." Mathematics of Computation 72.243 (2003): 1453-1471

    Examples
    --------
    >>> from scipy.stats.sampling import SimpleRatioUniforms
    >>> import numpy as np

    Suppose we have the normal distribution:

    >>> class StdNorm:
    ...     def pdf(self, x):
    ...         return np.exp(-0.5 * x**2)

    Notice that the PDF doesn't integrate to 1. We can either pass the exact
    area under the PDF during initialization of the generator or an upper
    bound to the exact area under the PDF. Also, it is recommended to pass
    the mode of the distribution to speed up the setup:

    >>> urng = np.random.default_rng()
    >>> dist = StdNorm()
    >>> rng = SimpleRatioUniforms(dist, mode=0,
    ...                           pdf_area=np.sqrt(2*np.pi),
    ...                           random_state=urng)

    Now, we can use the `rvs` method to generate samples from the distribution:

    >>> rvs = rng.rvs(10)

    If the CDF at mode is avaialble, it can be set to improve the performace of `rvs`:

    >>> from scipy.stats import norm
    >>> rng = SimpleRatioUniforms(dist, mode=0,
    ...                           pdf_area=np.sqrt(2*np.pi),
    ...                           cdf_at_mode=norm.cdf(0),
    ...                           random_state=urng)
    >>> rvs = rng.rvs(1000)

    We can check that the samples are from the given distribution by visualizing
    its histogram:

    >>> import matplotlib.pyplot as plt
    >>> x = np.linspace(rvs.min()-0.1, rvs.max()+0.1, 1000)
    >>> fx = 1/np.sqrt(2*np.pi) * dist.pdf(x)
    >>> fig, ax = plt.subplots()
    >>> ax.plot(x, fx, 'r-', lw=2, label='true distribution')
    >>> ax.hist(rvs, bins=10, density=True, alpha=0.8, label='random variates')
    >>> ax.set_xlabel('x')
    >>> ax.set_ylabel('PDF(x)')
    >>> ax.set_title('Simple Ratio-of-Uniforms Samples')
    >>> ax.legend()
    >>> plt.show()
    """

    def __cinit__(self,
                  dist,
                  *,
                  mode=None,
                  pdf_area=1,
                  domain=None,
                  cdf_at_mode=None,
                  random_state=None):
        (domain, pdf_area) = self._validate_args(dist, domain, pdf_area)

        # save all the arguments for pickling support
        self._kwargs = {
            'dist': dist,
            'mode': mode,
            'pdf_area': pdf_area,
            'domain': domain,
            'cdf_at_mode': cdf_at_mode,
            'random_state': random_state
        }

        cdef:
            unur_distr *distr
            unur_par *par
            unur_gen *rng

        self.callbacks = _unpack_dist(dist, "cont", meths=["pdf"])
        def _callback_wrapper(x, name):
            return self.callbacks[name](x)
        self._callback_wrapper = _callback_wrapper
        self._messages = MessageStream()
        _lock.acquire()
        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_cont_new()
            if self.distr == NULL:
                raise UNURANError(self._messages.get())
            _pack_distr(self.distr, self.callbacks)

            if domain is not None:
                self._check_errorcode(unur_distr_cont_set_domain(self.distr, domain[0],
                                                                 domain[1]))

            if mode is not None:
                self._check_errorcode(unur_distr_cont_set_mode(self.distr, mode))

            self._check_errorcode(unur_distr_cont_set_pdfarea(self.distr, pdf_area))

            self.par = unur_srou_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())

            if cdf_at_mode is not None:
                self._check_errorcode(unur_srou_set_cdfatmode(self.par, cdf_at_mode))
                # Always use squeeze when CDF at mode is given to improve performance
                self._check_errorcode(unur_srou_set_usesqueeze(self.par, True))

            self._set_rng(random_state)
        finally:
            _lock.release()

    cdef object _validate_args(self, dist, domain, pdf_area):
        # validate args
        domain = _validate_domain(domain, dist)
        if pdf_area < 0:
            raise ValueError("`pdf_area` must be > 0")
        return domain, pdf_area


UError = namedtuple('UError', ['max_error', 'mean_absolute_error'])


cdef class NumericalInversePolynomial(Method):
    """
    NumericalInversePolynomial(dist, *, mode=None, center=None, domain=None, order=5, u_resolution=1e-10, random_state=None)

    Polynomial interpolation based INVersion of CDF (PINV).

    PINV is a variant of numerical inversion, where the inverse CDF is approximated
    using Newton's interpolating formula. The interval ``[0,1]`` is split into several
    subintervals. In each of these, the inverse CDF is constructed at nodes ``(CDF(x),x)``
    for some points ``x`` in this subinterval. If the PDF is given, then the CDF is
    computed numerically from the given PDF using adaptive Gauss-Lobatto integration with
    5 points. Subintervals are split until the requested accuracy goal is reached.

    The method is not exact, as it only produces random variates of the approximated
    distribution. Nevertheless, the maximal tolerated approximation error can be set to
    be the resolution (but, of course, is bounded by the machine precision). We use the
    u-error ``|U - CDF(X)|`` to measure the error where ``X`` is the approximate
    percentile corressponding to the quantile ``U`` i.e. ``X = approx_ppf(U)``. We call
    the maximal tolerated u-error the u-resolution of the algorithm.

    Both the order of the interpolating polynomial and the u-resolution can be selected.
    Note that very small values of the u-resolution are possible but increase the cost
    for the setup step.

    The interpolating polynomials have to be computed in a setup step. However, it only
    works for distributions with bounded domain; for distributions with unbounded domain
    the tails are cut off such that the probability for the tail regions is small compared
    to the given u-resolution.

    The construction of the interpolation polynomial only works when the PDF is unimodal
    or when the PDF does not vanish between two modes.

    There are some restrictions for the given distribution:

    * The support of the distribution (i.e., the region where the PDF is strictly
      positive) must be connected. In practice this means, that the region where PDF
      is "not too small" must be connected. Unimodal densities satisfy this condition.
      If this condition is violated then the domain of the distribution might be
      truncated.
    * When the PDF is integrated numerically, then the given PDF must be continuous
      and should be smooth.
    * The PDF must be bounded.
    * The algorithm has problems when the distribution has heavy tails (as then the
      inverse CDF becomes very steep at 0 or 1) and the requested u-resolution is
      very small. E.g., the Cauchy distribution is likely to show this problem when
      the requested u-resolution is less then 1.e-12.


    Parameters
    ----------
    dist : object
        An instance of a class with a ``pdf`` or ``logpdf`` method,
        optionally a ``cdf`` method.

        * ``pdf``: PDF of the distribution. The signature of the PDF is expected to be:
          ``def pdf(self, x: float) -> float``, i.e., the PDF should accept a Python
          float and return a Python float. It doesn't need to integrate to 1,
          i.e., the PDF doesn't need to be normalized. This method is optional,
          but either ``pdf`` or ``logpdf`` need to be specified. If both are given,
          ``logpdf`` is used.
        * ``logpdf``: The log of the PDF of the distribution. The signature is
          the same as for ``pdf``. Similarly, log of the normalization constant
          of the PDF can be ignored. This method is optional, but either ``pdf`` or
          ``logpdf`` need to be specified. If both are given, ``logpdf`` is used.
        * ``cdf``: CDF of the distribution. This method is optional. If provided, it
          enables the calculation of "u-error". See `u_error`. Must have the same
          signature as the PDF.

    mode : float, optional
        (Exact) Mode of the distribution. Default is ``None``.
    center : float, optional
        Approximate location of the mode or the mean of the distribution. This location
        provides some information about the main part of the PDF and is used to avoid
        numerical problems. Default is ``None``.
    domain : list or tuple of length 2, optional
        The support of the distribution.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise the support is assumed to be :math:`(-\infty, \infty)`.

    order : int, optional
        Order of the interpolating polynomial. Valid orders are between 3 and 17.
        Higher orders result in fewer intervals for the approximations. Default
        is 5.
    u_resolution : float, optional
        Set maximal tolerated u-error. Values of u_resolution must at least 1.e-15 and
        1.e-5 at most. Notice that the resolution of most uniform random number sources
        is 2-32= 2.3e-10. Thus a value of 1.e-10 leads to an inversion algorithm that
        could be called exact. For most simulations slightly bigger values for the
        maximal error are enough as well. Default is 1e-10.
    random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    References
    ----------
    .. [1] Derflinger, Gerhard, Wolfgang Hörmann, and Josef Leydold. "Random variate
           generation by numerical inversion when only the density is known." ACM
           Transactions on Modeling and Computer Simulation (TOMACS) 20.4 (2010): 1-25.
    .. [2] UNU.RAN reference manual, Section 5.3.12,
           "PINV – Polynomial interpolation based INVersion of CDF",
           https://statmath.wu.ac.at/software/unuran/doc/unuran.html#PINV

    Examples
    --------
    >>> from scipy.stats.sampling import NumericalInversePolynomial
    >>> from scipy.stats import norm
    >>> import numpy as np

    To create a generator to sample from the standard normal distribution, do:

    >>> class StandardNormal:
    ...    def pdf(self, x):
    ...        return np.exp(-0.5 * x*x)
    ...
    >>> dist = StandardNormal()
    >>> urng = np.random.default_rng()
    >>> rng = NumericalInversePolynomial(dist, random_state=urng)

    Once a generator is created, samples can be drawn from the distribution by calling
    the `rvs` method:

    >>> rng.rvs()
    -1.5244996276336318

    To check that the random variates closely follow the given distribution, we can
    look at it's histogram:

    >>> import matplotlib.pyplot as plt
    >>> rvs = rng.rvs(10000)
    >>> x = np.linspace(rvs.min()-0.1, rvs.max()+0.1, 1000)
    >>> fx = norm.pdf(x)
    >>> plt.plot(x, fx, 'r-', lw=2, label='true distribution')
    >>> plt.hist(rvs, bins=20, density=True, alpha=0.8, label='random variates')
    >>> plt.xlabel('x')
    >>> plt.ylabel('PDF(x)')
    >>> plt.title('Numerical Inverse Polynomial Samples')
    >>> plt.legend()
    >>> plt.show()

    It is possible to estimate the u-error of the approximated PPF if the exact
    CDF is available during setup. To do so, pass a `dist` object with exact CDF of
    the distribution during initialization:

    >>> from scipy.special import ndtr
    >>> class StandardNormal:
    ...    def pdf(self, x):
    ...        return np.exp(-0.5 * x*x)
    ...    def cdf(self, x):
    ...        return ndtr(x)
    ...
    >>> dist = StandardNormal()
    >>> urng = np.random.default_rng()
    >>> rng = NumericalInversePolynomial(dist, random_state=urng)

    Now, the u-error can be estimated by calling the `u_error` method. It runs a
    Monte-Carlo simulation to estimate the u-error. By default, 100000 samples are
    used. To change this, you can pass the number of samples as an argument:

    >>> rng.u_error(sample_size=1000000)  # uses one million samples
    UError(max_error=8.785994154436594e-11, mean_absolute_error=2.930890027826552e-11)

    This returns a namedtuple which contains the maximum u-error and the mean
    absolute u-error.

    The u-error can be reduced by decreasing the u-resolution (maximum allowed u-error):

    >>> urng = np.random.default_rng()
    >>> rng = NumericalInversePolynomial(dist, u_resolution=1.e-12, random_state=urng)
    >>> rng.u_error(sample_size=1000000)
    UError(max_error=9.07496300328603e-13, mean_absolute_error=3.5255644517257716e-13)

    Note that this comes at the cost of increased setup time.

    The approximated PPF can be evaluated by calling the `ppf` method:

    >>> rng.ppf(0.975)
    1.9599639857012559
    >>> norm.ppf(0.975)
    1.959963984540054

    Since the PPF of the normal distribution is available as a special function, we
    can also check the x-error, i.e. the difference between the approximated PPF and
    exact PPF::

    >>> import matplotlib.pyplot as plt
    >>> u = np.linspace(0.01, 0.99, 1000)
    >>> approxppf = rng.ppf(u)
    >>> exactppf = norm.ppf(u)
    >>> error = np.abs(exactppf - approxppf)
    >>> plt.plot(u, error)
    >>> plt.xlabel('u')
    >>> plt.ylabel('error')
    >>> plt.title('Error between exact and approximated PPF (x-error)')
    >>> plt.show()
    """

    def __cinit__(self,
                  dist,
                  *,
                  mode=None,
                  center=None,
                  domain=None,
                  order=5,
                  u_resolution=1e-10,
                  random_state=None):
        (domain, order, u_resolution) = self._validate_args(
            dist, domain, order, u_resolution
        )

        # save all the arguments for pickling support
        self._kwargs = {
            'dist': dist,
            'center': center,
            'domain': domain,
            'order': order,
            'u_resolution': u_resolution,
            'random_state': random_state
        }

        cdef:
            unur_distr *distr
            unur_par *par
            unur_gen *rng

        # either logpdf or pdf are required: use meths = None and check separately
        self.callbacks = _unpack_dist(dist, "cont", meths=None, optional_meths=["cdf", "pdf", "logpdf"])
        if not ("pdf" in self.callbacks or "logpdf" in self.callbacks):
            msg = ("Either of the methods `pdf` or `logpdf` must be specified "
                   "for the distribution object `dist`.")
            raise ValueError(msg)
        def _callback_wrapper(x, name):
            return self.callbacks[name](x)
        self._callback_wrapper = _callback_wrapper
        self._messages = MessageStream()
        _lock.acquire()
        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_cont_new()
            if self.distr == NULL:
                raise UNURANError(self._messages.get())
            _pack_distr(self.distr, self.callbacks)

            if domain is not None:
                self._check_errorcode(unur_distr_cont_set_domain(self.distr, domain[0],
                                                                 domain[1]))

            if mode is not None:
                self._check_errorcode(unur_distr_cont_set_mode(self.distr, mode))
            if center is not None:
                self._check_errorcode(unur_distr_cont_set_center(self.distr, center))

            self.par = unur_pinv_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())

            self._check_errorcode(unur_pinv_set_order(self.par, order))
            self._check_errorcode(unur_pinv_set_u_resolution(self.par, u_resolution))
            # max_intervals is not part of the API. set it to the maximum
            # allowed value in UNU.RAN which is 1_000_000
            self._check_errorcode(unur_pinv_set_max_intervals(self.par, 1000000))
            # always keep CDF in SciPy while UNU.RAN default is False
            self._check_errorcode(unur_pinv_set_keepcdf(self.par, 1))

            self._set_rng(random_state)
        finally:
            _lock.release()

    cdef object _validate_args(self, dist, domain, order, u_resolution):
        domain = _validate_domain(domain, dist)
        # UNU.RAN raises warning and sets a default value. Prefer an error instead.
        if not (3 <= order <= 17 and int(order) == order):
            raise ValueError("`order` must be an integer in the range [3, 17].")
        # UNU.RAN seg faults when u_resolution is not finite. And throws a warning if
        # it is not in the range [1.e-15, 1.e-5]. Prefer an error instead.
        if not (1e-15 <= u_resolution <= 1e-5):
            raise ValueError("`u_resolution` must be between 1e-15 and 1e-5.")
        return (domain, order, u_resolution)

    @property
    def intervals(self):
        """Get the number of intervals used in the computation."""
        return unur_pinv_get_n_intervals(self.rng)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _cdf(self, const double *x, double *out, size_t N) except *:
        cdef:
            size_t i
            ccallback_t callback
            PyObject *type
            PyObject *value
            PyObject *traceback

        error = 0

        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)
            init_unuran_callback(&callback, self._callback_wrapper)
            for i in range(N):
                out[i] = unur_pinv_eval_approxcdf(self.rng, x[i])
                if PyErr_Occurred():
                    error = 1
                    return
                if out[i] == UNUR_INFINITY or out[i] == -UNUR_INFINITY:
                    raise UNURANError(self._messages.get())
        finally:
            if error:
                PyErr_Fetch(&type, &value, &traceback)
            _lock.release()
            if error:
                PyErr_Restore(type, value, traceback)
            release_unuran_callback(&callback)

    def cdf(self, x):
        """
        cdf(x)

        Approximated cumulative distribution function of the given distribution.

        Parameters
        ----------
        x : array_like
            Quantiles, with the last axis of `x` denoting the components.

        Returns
        -------
        cdf : array_like
            Approximated cumulative distribution function evaluated at `x`.
        """
        x = np.asarray(x, dtype='d')
        oshape = x.shape
        x = x.ravel()
        cdef double[::1] x_view = np.ascontiguousarray(x)
        cdef double[::1] out = np.empty_like(x)
        if x.size == 0:
            return np.asarray(out).reshape(oshape)
        self._cdf(&x_view[0], &out[0], len(x_view))
        return np.asarray(out).reshape(oshape)[()]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _ppf(self, const double *u, double *out, size_t N):
        cdef:
            size_t i
        for i in range(N):
            out[i] = unur_pinv_eval_approxinvcdf(self.rng, u[i])

    def ppf(self, u):
        """
        ppf(u)

        Approximated PPF of the given distribution.

        Parameters
        ----------
        u : array_like
            Quantiles.

        Returns
        -------
        ppf : array_like
            Percentiles corresponding to given quantiles `u`.
        """
        u = np.asarray(u, dtype='d')
        oshape = u.shape
        u = u.ravel()
        # UNU.RAN fills in ends of the support when u < 0 or u > 1 while
        # SciPy fills in nans. Prefer SciPy behaviour.
        cond0 = 0 <= u
        cond1 = u <= 1
        cond2 = cond0 & cond1
        goodu = argsreduce(cond2, u)[0]
        out = np.empty_like(u)
        cdef double[::1] u_view = np.ascontiguousarray(goodu)
        cdef double[::1] goodout = np.empty_like(u_view)
        if cond2.any():
            self._ppf(&u_view[0], &goodout[0], len(goodu))
        np.place(out, cond2, goodout)
        np.place(out, ~cond2, np.nan)
        return np.asarray(out).reshape(oshape)[()]

    def u_error(self, sample_size=100000):
        """
        u_error(sample_size=100000)

        Estimate the u-error of the approximation using Monte Carlo simulation.
        This is only available if the generator was initialized with a `dist`
        object containing the implementation of the exact CDF under `cdf` method.

        Parameters
        ----------
        sample_size : int, optional
            Number of samples to use for the estimation. It must be greater than
            or equal to 1000.

        Returns
        -------
        max_error : float
            Maximum u-error.
        mean_absolute_error : float
            Mean absolute u-error.
        """
        # UNU.RAN doesn't return a proper error code for this condition.
        if sample_size < 1000:
            raise ValueError("`sample_size` must be greater than or equal to 1000.")
        if 'cdf' not in self.callbacks:
            raise ValueError("Exact CDF required but not found. Reinitialize the generator "
                             " with a `dist` object that contains a `cdf` method to enable "
                             " the estimation of u-error.")
        cdef double max_error, mae
        cdef ccallback_t callback
        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)
            init_unuran_callback(&callback, self._callback_wrapper)
            self._check_errorcode(unur_pinv_estimate_error(self.rng, sample_size,
                                                           &max_error, &mae))
        finally:
            _lock.release()
            release_unuran_callback(&callback)
        return UError(max_error, mae)


    def qrvs(self, size=None, d=None, qmc_engine=None):
        """
        qrvs(size=None, d=None, qmc_engine=None)

        Quasi-random variates of the given RV.

        The `qmc_engine` is used to draw uniform quasi-random variates, and
        these are converted to quasi-random variates of the given RV using
        inverse transform sampling.

        Parameters
        ----------
        size : int, tuple of ints, or None; optional
            Defines shape of random variates array. Default is ``None``.
        d : int or None, optional
            Defines dimension of uniform quasi-random variates to be
            transformed. Default is ``None``.
        qmc_engine : scipy.stats.qmc.QMCEngine(d=1), optional
            Defines the object to use for drawing
            quasi-random variates. Default is ``None``, which uses
            `scipy.stats.qmc.Halton(1)`.

        Returns
        -------
        rvs : ndarray or scalar
            Quasi-random variates. See Notes for shape information.

        Notes
        -----
        The shape of the output array depends on `size`, `d`, and `qmc_engine`.
        The intent is for the interface to be natural, but the detailed rules
        to achieve this are complicated.

        - If `qmc_engine` is ``None``, a `scipy.stats.qmc.Halton` instance is
          created with dimension `d`. If `d` is not provided, ``d=1``.
        - If `qmc_engine` is not ``None`` and `d` is ``None``, `d` is
          determined from the dimension of the `qmc_engine`.
        - If `qmc_engine` is not ``None`` and `d` is not ``None`` but the
          dimensions are inconsistent, a ``ValueError`` is raised.
        - After `d` is determined according to the rules above, the output
          shape is ``tuple_shape + d_shape``, where:

              - ``tuple_shape = tuple()`` if `size` is ``None``,
              - ``tuple_shape = (size,)`` if `size` is an ``int``,
              - ``tuple_shape = size`` if `size` is a sequence,
              - ``d_shape = tuple()`` if `d` is ``None`` or `d` is 1, and
              - ``d_shape = (d,)`` if `d` is greater than 1.

        The elements of the returned array are part of a low-discrepancy
        sequence. If `d` is 1, this means that none of the samples are truly
        independent. If `d` > 1, each slice ``rvs[..., i]`` will be of a
        quasi-independent sequence; see `scipy.stats.qmc.QMCEngine` for
        details. Note that when `d` > 1, the samples returned are still those
        of the provided univariate distribution, not a multivariate
        generalization of that distribution.

        """
        qmc_engine, d = _validate_qmc_input(qmc_engine, d)
        # `rvs` is flexible about whether `size` is an int or tuple, so this
        # should be, too.
        try:
            if size is None:
                tuple_size = (1, )
            else:
                tuple_size = tuple(size)
        except TypeError:
            tuple_size = (size,)

        cdef unur_urng *unuran_urng
        cdef double[::1] qrvs_view
        N = 1 if size is None else np.prod(size)
        N = N*d
        qrvs_view = np.empty(N, dtype=np.float64)
        _lock.acquire()
        try:
            # the call below must be under a lock
            unuran_urng = self._urng_builder.get_qurng(size=N, qmc_engine=qmc_engine)
            unur_chg_urng(self.rng, unuran_urng)
            self._rvs_cont(qrvs_view)
            self.set_random_state(self.numpy_rng)
            qrvs = np.asarray(qrvs_view).reshape(tuple_size + (d,))
        finally:
            _lock.release()

        # Output reshaping for user convenience
        if size is None:
            return qrvs.squeeze()[()]
        else:
            if d == 1:
                return qrvs.reshape(tuple_size)
            else:
                return qrvs.reshape(tuple_size + (d,))


cdef class NumericalInverseHermite(Method):
    """
    NumericalInverseHermite(dist, *, domain=None, order=3, u_resolution=1e-12, construction_points=None, random_state=None)

    Hermite interpolation based INVersion of CDF (HINV).

    HINV is a variant of numerical inversion, where the inverse CDF is approximated using
    Hermite interpolation, i.e., the interval [0,1] is split into several intervals and
    in each interval the inverse CDF is approximated by polynomials constructed by means
    of values of the CDF and PDF at interval boundaries. This makes it possible to improve
    the accuracy by splitting a particular interval without recomputations in unaffected
    intervals. Three types of splines are implemented: linear, cubic, and quintic
    interpolation. For linear interpolation only the CDF is required. Cubic interpolation
    also requires PDF and quintic interpolation PDF and its derivative.

    These splines have to be computed in a setup step. However, it only works for
    distributions with bounded domain; for distributions with unbounded domain the tails
    are chopped off such that the probability for the tail regions is small compared to
    the given u-resolution.

    The method is not exact, as it only produces random variates of the approximated
    distribution. Nevertheless, the maximal numerical error in "u-direction" (i.e.
    ``|U - CDF(X)|`` where ``X`` is the approximate percentile corresponding to the
    quantile ``U`` i.e. ``X = approx_ppf(U)``) can be set to the
    required resolution (within machine precision). Notice that very small values of
    the u-resolution are possible but may increase the cost for the setup step.

    Parameters
    ----------
    dist : object
        An instance of a class with a ``cdf`` and optionally a ``pdf`` and ``dpdf`` method.

        * ``cdf``: CDF of the distribution. The signature of the CDF is expected to be:
          ``def cdf(self, x: float) -> float``. i.e. the CDF should accept a Python
          float and return a Python float.
        * ``pdf``: PDF of the distribution. This method is optional when ``order=1``.
          Must have the same signature as the PDF.
        * ``dpdf``: Derivative of the PDF w.r.t the variate (i.e. ``x``). This method is
          optional with ``order=1`` or ``order=3``. Must have the same signature as the CDF.

    domain : list or tuple of length 2, optional
        The support of the distribution.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise the support is assumed to be :math:`(-\infty, \infty)`.

    order : int, default: ``3``
        Set order of Hermite interpolation. Valid orders are 1, 3, and 5.
        Valid orders are 1, 3, and 5. Notice that order greater than 1 requires the density
        of the distribution, and order greater than 3 even requires the derivative of the
        density. Using order 1 results for most distributions in a huge number of intervals
        and is therefore not recommended. If the maximal error in u-direction is very small
        (say smaller than 1.e-10), order 5 is recommended as it leads to considerably fewer
        design points, as long there are no poles or heavy tails.
    u_resolution : float, default: ``1e-12``
        Set maximal tolerated u-error. Notice that the resolution of most uniform random
        number sources is 2-32= 2.3e-10. Thus a value of 1.e-10 leads to an inversion
        algorithm that could be called exact. For most simulations slightly bigger values
        for the maximal error are enough as well. Default is 1e-12.
    construction_points : array_like, optional
        Set starting construction points (nodes) for Hermite interpolation. As the possible
        maximal error is only estimated in the setup it may be necessary to set some
        special design points for computing the Hermite interpolation to guarantee that the
        maximal u-error can not be bigger than desired. Such points are points where the
        density is not differentiable or has a local extremum.
    random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    Notes
    -----
    `NumericalInverseHermite` approximates the inverse of a continuous
    statistical distribution's CDF with a Hermite spline. Order of the
    hermite spline can be specified by passing the `order` parameter.

    As described in [1]_, it begins by evaluating the distribution's PDF and
    CDF at a mesh of quantiles ``x`` within the distribution's support.
    It uses the results to fit a Hermite spline ``H`` such that
    ``H(p) == x``, where ``p`` is the array of percentiles corresponding
    with the quantiles ``x``. Therefore, the spline approximates the inverse
    of the distribution's CDF to machine precision at the percentiles ``p``,
    but typically, the spline will not be as accurate at the midpoints between
    the percentile points::

        p_mid = (p[:-1] + p[1:])/2

    so the mesh of quantiles is refined as needed to reduce the maximum
    "u-error"::

        u_error = np.max(np.abs(dist.cdf(H(p_mid)) - p_mid))

    below the specified tolerance `u_resolution`. Refinement stops when the required
    tolerance is achieved or when the number of mesh intervals after the next
    refinement could exceed the maximum allowed number of intervals, which is
    100000.

    References
    ----------
    .. [1] Hörmann, Wolfgang, and Josef Leydold. "Continuous random variate
           generation by fast numerical inversion." ACM Transactions on
           Modeling and Computer Simulation (TOMACS) 13.4 (2003): 347-362.
    .. [2] UNU.RAN reference manual, Section 5.3.5,
           "HINV - Hermite interpolation based INVersion of CDF",
           https://statmath.wu.ac.at/software/unuran/doc/unuran.html#HINV

    Examples
    --------
    >>> from scipy.stats.sampling import NumericalInverseHermite
    >>> from scipy.stats import norm, genexpon
    >>> from scipy.special import ndtr
    >>> import numpy as np

    To create a generator to sample from the standard normal distribution, do:

    >>> class StandardNormal:
    ...     def pdf(self, x):
    ...        return 1/np.sqrt(2*np.pi) * np.exp(-x**2 / 2)
    ...     def cdf(self, x):
    ...        return ndtr(x)
    ...
    >>> dist = StandardNormal()
    >>> urng = np.random.default_rng()
    >>> rng = NumericalInverseHermite(dist, random_state=urng)

    The `NumericalInverseHermite` has a method that approximates the PPF of the
    distribution.

    >>> rng = NumericalInverseHermite(dist)
    >>> p = np.linspace(0.01, 0.99, 99) # percentiles from 1% to 99%
    >>> np.allclose(rng.ppf(p), norm.ppf(p))
    True

    Depending on the implementation of the distribution's random sampling
    method, the random variates generated may be nearly identical, given
    the same random state.

    >>> dist = genexpon(9, 16, 3)
    >>> rng = NumericalInverseHermite(dist)
    >>> # `seed` ensures identical random streams are used by each `rvs` method
    >>> seed = 500072020
    >>> rvs1 = dist.rvs(size=100, random_state=np.random.default_rng(seed))
    >>> rvs2 = rng.rvs(size=100, random_state=np.random.default_rng(seed))
    >>> np.allclose(rvs1, rvs2)
    True

    To check that the random variates closely follow the given distribution, we can
    look at its histogram:

    >>> import matplotlib.pyplot as plt
    >>> dist = StandardNormal()
    >>> rng = NumericalInverseHermite(dist)
    >>> rvs = rng.rvs(10000)
    >>> x = np.linspace(rvs.min()-0.1, rvs.max()+0.1, 1000)
    >>> fx = norm.pdf(x)
    >>> plt.plot(x, fx, 'r-', lw=2, label='true distribution')
    >>> plt.hist(rvs, bins=20, density=True, alpha=0.8, label='random variates')
    >>> plt.xlabel('x')
    >>> plt.ylabel('PDF(x)')
    >>> plt.title('Numerical Inverse Hermite Samples')
    >>> plt.legend()
    >>> plt.show()

    Given the derivative of the PDF w.r.t the variate (i.e. ``x``), we can use
    quintic Hermite interpolation to approximate the PPF by passing the `order`
    parameter:

    >>> class StandardNormal:
    ...     def pdf(self, x):
    ...        return 1/np.sqrt(2*np.pi) * np.exp(-x**2 / 2)
    ...     def dpdf(self, x):
    ...        return -1/np.sqrt(2*np.pi) * x * np.exp(-x**2 / 2)
    ...     def cdf(self, x):
    ...        return ndtr(x)
    ...
    >>> dist = StandardNormal()
    >>> urng = np.random.default_rng()
    >>> rng = NumericalInverseHermite(dist, order=5, random_state=urng)

    Higher orders result in a fewer number of intervals:

    >>> rng3 = NumericalInverseHermite(dist, order=3)
    >>> rng5 = NumericalInverseHermite(dist, order=5)
    >>> rng3.intervals, rng5.intervals
    (3000, 522)

    The u-error can be estimated by calling the `u_error` method. It runs a small
    Monte-Carlo simulation to estimate the u-error. By default, 100,000 samples are
    used. This can be changed by passing the `sample_size` argument:

    >>> rng1 = NumericalInverseHermite(dist, u_resolution=1e-10)
    >>> rng1.u_error(sample_size=1000000)  # uses one million samples
    UError(max_error=9.53167544892608e-11, mean_absolute_error=2.2450136432146864e-11)

    This returns a namedtuple which contains the maximum u-error and the mean
    absolute u-error.

    The u-error can be reduced by decreasing the u-resolution (maximum allowed u-error):

    >>> rng2 = NumericalInverseHermite(dist, u_resolution=1e-13)
    >>> rng2.u_error(sample_size=1000000)
    UError(max_error=9.32027892364129e-14, mean_absolute_error=1.5194172675685075e-14)

    Note that this comes at the cost of increased setup time and number of intervals.

    >>> rng1.intervals
    1022
    >>> rng2.intervals
    5687
    >>> from timeit import timeit
    >>> f = lambda: NumericalInverseHermite(dist, u_resolution=1e-10)
    >>> timeit(f, number=1)
    0.017409582000254886  # may vary
    >>> f = lambda: NumericalInverseHermite(dist, u_resolution=1e-13)
    >>> timeit(f, number=1)
    0.08671202100003939  # may vary

    Since the PPF of the normal distribution is available as a special function, we
    can also check the x-error, i.e. the difference between the approximated PPF and
    exact PPF::

    >>> import matplotlib.pyplot as plt
    >>> u = np.linspace(0.01, 0.99, 1000)
    >>> approxppf = rng.ppf(u)
    >>> exactppf = norm.ppf(u)
    >>> error = np.abs(exactppf - approxppf)
    >>> plt.plot(u, error)
    >>> plt.xlabel('u')
    >>> plt.ylabel('error')
    >>> plt.title('Error between exact and approximated PPF (x-error)')
    >>> plt.show()

    """
    cdef double[::1] construction_points_array

    def __cinit__(self,
                  dist,
                  *,
                  domain=None,
                  order=3,
                  u_resolution=1e-12,
                  construction_points=None,
                  random_state=None):
        domain, order, u_resolution = self._validate_args(dist, domain, order,
                                                          u_resolution, construction_points)

        # save all the arguments for pickling support
        self._kwargs = {
            'dist': dist,
            'domain': domain,
            'order': order,
            'u_resolution': u_resolution,
            'construction_points': construction_points,
            'random_state': random_state
        }

        cdef:
            unur_distr *distr
            unur_par *par

        self.callbacks = _unpack_dist(dist, "cont", meths=["cdf"], optional_meths=["pdf", "dpdf"])
        def _callback_wrapper(x, name):
            return self.callbacks[name](x)
        self._callback_wrapper = _callback_wrapper
        self._messages = MessageStream()
        _lock.acquire()
        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_cont_new()
            if self.distr == NULL:
                raise UNURANError(self._messages.get())
            _pack_distr(self.distr, self.callbacks)

            if domain is not None:
                self._check_errorcode(unur_distr_cont_set_domain(self.distr, domain[0],
                                                                 domain[1]))

            self.par = unur_hinv_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())

            self._check_errorcode(unur_hinv_set_order(self.par, order))
            self._check_errorcode(unur_hinv_set_u_resolution(self.par, u_resolution))
            self._check_errorcode(unur_hinv_set_cpoints(self.par, &self.construction_points_array[0],
                                                        len(self.construction_points_array)))
            self._set_rng(random_state)
        finally:
            _lock.release()

    def _validate_args(self, dist, domain, order, u_resolution, construction_points):
        domain = _validate_domain(domain, dist)
        # UNU.RAN raises warning and sets a default value. Prefer an error instead.
        if order not in {1, 3, 5}:
            raise ValueError("`order` must be either 1, 3, or 5.")
        u_resolution = float(u_resolution)
        self.construction_points_array = np.ascontiguousarray(construction_points,
                                                              dtype=np.float64)
        if len(self.construction_points_array) == 0:
            raise ValueError("`construction_points` must be a non-empty array.")
        return (domain, order, u_resolution)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _ppf(self, const double *u, double *out, size_t N):
        cdef:
            size_t i
        for i in range(N):
            out[i] = unur_hinv_eval_approxinvcdf(self.rng, u[i])

    def ppf(self, u):
        """
        ppf(u)

        Approximated PPF of the given distribution.

        Parameters
        ----------
        u : array_like
            Quantiles.

        Returns
        -------
        ppf : array_like
            Percentiles corresponding to given quantiles `u`.
        """
        u = np.asarray(u, dtype='d')
        oshape = u.shape
        u = u.ravel()
        # UNU.RAN fills in ends of the support when u < 0 or u > 1 while
        # SciPy fills in nans. Prefer SciPy behaviour.
        cond0 = 0 <= u
        cond1 = u <= 1
        cond2 = cond0 & cond1
        goodu = argsreduce(cond2, u)[0]
        out = np.empty_like(u)
        cdef double[::1] u_view = np.ascontiguousarray(goodu)
        cdef double[::1] goodout = np.empty_like(u_view)
        if cond2.any():
            self._ppf(&u_view[0], &goodout[0], len(goodu))
        np.place(out, cond2, goodout)
        np.place(out, ~cond2, np.nan)
        return np.asarray(out).reshape(oshape)[()]

    def u_error(self, sample_size=100000):
        """
        u_error(sample_size=100000)

        Estimate the u-error of the approximation using Monte Carlo simulation.
        This is only available if the generator was initialized with a `dist`
        object containing the implementation of the exact CDF under `cdf` method.

        Parameters
        ----------
        sample_size : int, optional
            Number of samples to use for the estimation. It must be greater than
            or equal to 1000.

        Returns
        -------
        max_error : float
            Maximum u-error.
        mean_absolute_error : float
            Mean absolute u-error.
        """
        # UNU.RAN doesn't return a proper error code for this condition.
        if sample_size < 1000:
            raise ValueError("`sample_size` must be greater than or equal to 1000.")
        cdef double max_error, mae
        cdef ccallback_t callback
        _lock.acquire()
        try:
            self._messages.clear()
            unur_set_stream(self._messages.handle)
            init_unuran_callback(&callback, self._callback_wrapper)
            self._check_errorcode(unur_hinv_estimate_error(self.rng, sample_size,
                                                           &max_error, &mae))
        finally:
            _lock.release()
            release_unuran_callback(&callback)
        return UError(max_error, mae)

    def qrvs(self, size=None, d=None, qmc_engine=None):
        """
        qrvs(size=None, d=None, qmc_engine=None)

        Quasi-random variates of the given RV.

        The `qmc_engine` is used to draw uniform quasi-random variates, and
        these are converted to quasi-random variates of the given RV using
        inverse transform sampling.

        Parameters
        ----------
        size : int, tuple of ints, or None; optional
            Defines shape of random variates array. Default is ``None``.
        d : int or None, optional
            Defines dimension of uniform quasi-random variates to be
            transformed. Default is ``None``.
        qmc_engine : scipy.stats.qmc.QMCEngine(d=1), optional
            Defines the object to use for drawing
            quasi-random variates. Default is ``None``, which uses
            `scipy.stats.qmc.Halton(1)`.

        Returns
        -------
        rvs : ndarray or scalar
            Quasi-random variates. See Notes for shape information.

        Notes
        -----
        The shape of the output array depends on `size`, `d`, and `qmc_engine`.
        The intent is for the interface to be natural, but the detailed rules
        to achieve this are complicated.

        - If `qmc_engine` is ``None``, a `scipy.stats.qmc.Halton` instance is
          created with dimension `d`. If `d` is not provided, ``d=1``.
        - If `qmc_engine` is not ``None`` and `d` is ``None``, `d` is
          determined from the dimension of the `qmc_engine`.
        - If `qmc_engine` is not ``None`` and `d` is not ``None`` but the
          dimensions are inconsistent, a ``ValueError`` is raised.
        - After `d` is determined according to the rules above, the output
          shape is ``tuple_shape + d_shape``, where:

              - ``tuple_shape = tuple()`` if `size` is ``None``,
              - ``tuple_shape = (size,)`` if `size` is an ``int``,
              - ``tuple_shape = size`` if `size` is a sequence,
              - ``d_shape = tuple()`` if `d` is ``None`` or `d` is 1, and
              - ``d_shape = (d,)`` if `d` is greater than 1.

        The elements of the returned array are part of a low-discrepancy
        sequence. If `d` is 1, this means that none of the samples are truly
        independent. If `d` > 1, each slice ``rvs[..., i]`` will be of a
        quasi-independent sequence; see `scipy.stats.qmc.QMCEngine` for
        details. Note that when `d` > 1, the samples returned are still those
        of the provided univariate distribution, not a multivariate
        generalization of that distribution.

        """
        qmc_engine, d = _validate_qmc_input(qmc_engine, d)
        # `rvs` is flexible about whether `size` is an int or tuple, so this
        # should be, too.
        try:
            if size is None:
                tuple_size = (1, )
            else:
                tuple_size = tuple(size)
        except TypeError:
            tuple_size = (size,)

        cdef unur_urng *unuran_urng
        cdef double[::1] qrvs_view
        N = 1 if size is None else np.prod(size)
        N = N*d
        qrvs_view = np.empty(N, dtype=np.float64)
        _lock.acquire()
        try:
            # the call below must be under a lock
            unuran_urng = self._urng_builder.get_qurng(size=N, qmc_engine=qmc_engine)
            unur_chg_urng(self.rng, unuran_urng)
            self._rvs_cont(qrvs_view)
            self.set_random_state(self.numpy_rng)
            qrvs = np.asarray(qrvs_view).reshape(tuple_size + (d,))
        finally:
            _lock.release()

        # Output reshaping for user convenience
        if size is None:
            return qrvs.squeeze()[()]
        else:
            if d == 1:
                return qrvs.reshape(tuple_size)
            else:
                return qrvs.reshape(tuple_size + (d,))

    @property
    def intervals(self):
        """
        Get number of nodes (design points) used for Hermite interpolation in the
        generator object. The number of intervals is the number of nodes minus 1.
        """
        return unur_hinv_get_n_intervals(self.rng)

    @property
    def midpoint_error(self):
        return self.u_error()[0]


cdef class DiscreteAliasUrn(Method):
    r"""
    DiscreteAliasUrn(dist, *, domain=None, urn_factor=1, random_state=None)

    Discrete Alias-Urn Method.

    This method is used to sample from univariate discrete distributions with
    a finite domain. It uses the probability vector of size :math:`N` or a
    probability mass function with a finite support to generate random
    numbers from the distribution.

    Parameters
    ----------
    dist : array_like or object, optional
        Probability vector (PV) of the distribution. If PV isn't available,
        an instance of a class with a ``pmf`` method is expected. The signature
        of the PMF is expected to be: ``def pmf(self, k: int) -> float``. i.e. it
        should accept a Python integer and return a Python float.
    domain : int, optional
        Support of the PMF. If a probability vector (``pv``) is not available, a
        finite domain must be given. i.e. the PMF must have a finite support.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise, the support is assumed to be ``(0, len(pv))``. When this
          parameter is passed in combination with a probability vector, ``domain[0]``
          is used to relocate the distribution from ``(0, len(pv))`` to
          ``(domain[0], domain[0]+len(pv))`` and ``domain[1]`` is ignored. See Notes
          and tutorial for a more detailed explanation.

    urn_factor : float, optional
        Size of the urn table *relative* to the size of the probability
        vector. It must not be less than 1. Larger tables result in faster
        generation times but require a more expensive setup. Default is 1.
    random_state : {None, int, `numpy.random.Generator`,
                        `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    Notes
    -----
    This method works when either a finite probability vector is available or
    the PMF of the distribution is available. In case a PMF is only available,
    the *finite* support (domain) of the PMF must also be given. It is
    recommended to first obtain the probability vector by evaluating the PMF
    at each point in the support and then using it instead.

    If a probability vector is given, it must be a 1-dimensional array of
    non-negative floats without any ``inf`` or ``nan`` values. Also, there
    must be at least one non-zero entry otherwise an exception is raised.

    By default, the probability vector is indexed starting at 0. However, this
    can be changed by passing a ``domain`` parameter. When ``domain`` is given
    in combination with the PV, it has the effect of relocating the
    distribution from ``(0, len(pv))`` to ``(domain[0]``, ``domain[0] + len(pv))``.
    ``domain[1]`` is ignored in this case.

    The parameter ``urn_factor`` can be increased for faster generation at the
    cost of increased setup time. This method uses a table for random
    variate generation. ``urn_factor`` controls the size of this table
    relative to the size of the probability vector (or width of the support,
    in case a PV is not available). As this table is computed during setup
    time, increasing this parameter linearly increases the time required to
    setup. It is recommended to keep this parameter under 2.

    References
    ----------
    .. [1] UNU.RAN reference manual, Section 5.8.2,
           "DAU - (Discrete) Alias-Urn method",
           http://statmath.wu.ac.at/software/unuran/doc/unuran.html#DAU
    .. [2] A.J. Walker (1977). An efficient method for generating discrete
           random variables with general distributions, ACM Trans. Math.
           Software 3, pp. 253-256.

    Examples
    --------
    >>> from scipy.stats.sampling import DiscreteAliasUrn
    >>> import numpy as np

    To create a random number generator using a probability vector, use:

    >>> pv = [0.1, 0.3, 0.6]
    >>> urng = np.random.default_rng()
    >>> rng = DiscreteAliasUrn(pv, random_state=urng)

    The RNG has been setup. Now, we can now use the `rvs` method to
    generate samples from the distribution:

    >>> rvs = rng.rvs(size=1000)

    To verify that the random variates follow the given distribution, we can
    use the chi-squared test (as a measure of goodness-of-fit):

    >>> from scipy.stats import chisquare
    >>> _, freqs = np.unique(rvs, return_counts=True)
    >>> freqs = freqs / np.sum(freqs)
    >>> freqs
    array([0.092, 0.292, 0.616])
    >>> chisquare(freqs, pv).pvalue
    0.9993602047563164

    As the p-value is very high, we fail to reject the null hypothesis that
    the observed frequencies are the same as the expected frequencies. Hence,
    we can safely assume that the variates have been generated from the given
    distribution. Note that this just gives the correctness of the algorithm
    and not the quality of the samples.

    If a PV is not available, an instance of a class with a PMF method and a
    finite domain can also be passed.

    >>> urng = np.random.default_rng()
    >>> class Binomial:
    ...     def __init__(self, n, p):
    ...         self.n = n
    ...         self.p = p
    ...     def pmf(self, x):
    ...         # note that the pmf doesn't need to be normalized.
    ...         return self.p**x * (1-self.p)**(self.n-x)
    ...     def support(self):
    ...         return (0, self.n)
    ...
    >>> n, p = 10, 0.2
    >>> dist = Binomial(n, p)
    >>> rng = DiscreteAliasUrn(dist, random_state=urng)

    Now, we can sample from the distribution using the `rvs` method
    and also measure the goodness-of-fit of the samples:

    >>> rvs = rng.rvs(1000)
    >>> _, freqs = np.unique(rvs, return_counts=True)
    >>> freqs = freqs / np.sum(freqs)
    >>> obs_freqs = np.zeros(11)  # some frequencies may be zero.
    >>> obs_freqs[:freqs.size] = freqs
    >>> pv = [dist.pmf(i) for i in range(0, 11)]
    >>> pv = np.asarray(pv) / np.sum(pv)
    >>> chisquare(obs_freqs, pv).pvalue
    0.9999999999999999

    To check that the samples have been drawn from the correct distribution,
    we can visualize the histogram of the samples:

    >>> import matplotlib.pyplot as plt
    >>> rvs = rng.rvs(1000)
    >>> fig = plt.figure()
    >>> ax = fig.add_subplot(111)
    >>> x = np.arange(0, n+1)
    >>> fx = dist.pmf(x)
    >>> fx = fx / fx.sum()
    >>> ax.plot(x, fx, 'bo', label='true distribution')
    >>> ax.vlines(x, 0, fx, lw=2)
    >>> ax.hist(rvs, bins=np.r_[x, n+1]-0.5, density=True, alpha=0.5,
    ...         color='r', label='samples')
    >>> ax.set_xlabel('x')
    >>> ax.set_ylabel('PMF(x)')
    >>> ax.set_title('Discrete Alias Urn Samples')
    >>> plt.legend()
    >>> plt.show()

    To set the ``urn_factor``, use:

    >>> rng = DiscreteAliasUrn(pv, urn_factor=2, random_state=urng)

    This uses a table twice the size of the probability vector to generate
    random variates from the distribution.
    """
    cdef double[::1] pv_view

    def __cinit__(self,
                  dist,
                  *,
                  domain=None,
                  urn_factor=1,
                  random_state=None):
        cdef double[::1] pv_view
        (pv_view, domain) = self._validate_args(dist, domain)
        # increment ref count of pv_view to make sure it doesn't get garbage collected.
        self.pv_view = pv_view
        # save all the arguments for pickling support
        self._kwargs = {'dist': dist, 'domain': domain, 'urn_factor': urn_factor, 'random_state': random_state}

        cdef:
            unur_distr *distr
            unur_par *par
            unur_gen *rng

        self._messages = MessageStream()
        _lock.acquire()
        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_discr_new()
            if self.distr == NULL:
                raise UNURANError(self._messages.get())

            n_pv = len(pv_view)
            self._check_errorcode(unur_distr_discr_set_pv(self.distr, &pv_view[0], n_pv))

            if domain is not None:
                self._check_errorcode(unur_distr_discr_set_domain(self.distr, domain[0],
                                                                  domain[1]))

            self.par = unur_dau_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())
            self._check_errorcode(unur_dau_set_urnfactor(self.par, urn_factor))

            self._set_rng(random_state)
        finally:
            _lock.release()

    cdef object _validate_args(self, dist, domain):
        cdef double[::1] pv_view

        domain = _validate_domain(domain, dist)
        if domain is not None:
            if not np.isfinite(domain).all():
                raise ValueError("`domain` must be finite.")
        else:
            if hasattr(dist, 'pmf'):
                raise ValueError("`domain` must be provided when the "
                                 "probability vector is not available.")
        if hasattr(dist, 'pmf'):
            # we assume the PMF accepts and return floats. So, we need
            # to vectorize it to call with an array of points in the domain.
            pmf = np.vectorize(dist.pmf)
            k = np.arange(domain[0], domain[1]+1)
            pv = pmf(k)
            try:
                pv_view = _validate_pv(pv)
            except ValueError as err:
                msg = "PMF returned invalid values: " + err.args[0]
                raise ValueError(msg) from None
        else:
            pv_view = _validate_pv(dist)

        return pv_view, domain


cdef class DiscreteGuideTable(Method):
    r"""
    DiscreteGuideTable(dist, *, domain=None, guide_factor=1, random_state=None)

    Discrete Guide Table method.

    The Discrete Guide Table method  samples from arbitrary, but finite,
    probability vectors. It uses the probability vector of size :math:`N` or a
    probability mass function with a finite support to generate random
    numbers from the distribution. Discrete Guide Table has a very slow set up
    (linear with the vector length) but provides very fast sampling.

    Parameters
    ----------
    dist : array_like or object, optional
        Probability vector (PV) of the distribution. If PV isn't available,
        an instance of a class with a ``pmf`` method is expected. The signature
        of the PMF is expected to be: ``def pmf(self, k: int) -> float``. i.e. it
        should accept a Python integer and return a Python float.
    domain : int, optional
        Support of the PMF. If a probability vector (``pv``) is not available, a
        finite domain must be given. i.e. the PMF must have a finite support.
        Default is ``None``. When ``None``:

        * If a ``support`` method is provided by the distribution object
          `dist`, it is used to set the domain of the distribution.
        * Otherwise, the support is assumed to be ``(0, len(pv))``. When this
          parameter is passed in combination with a probability vector, ``domain[0]``
          is used to relocate the distribution from ``(0, len(pv))`` to
          ``(domain[0], domain[0]+len(pv))`` and ``domain[1]`` is ignored. See Notes
          and tutorial for a more detailed explanation.
    guide_factor: int, optional
        Size of the guide table relative to length of PV. Larger guide tables
        result in faster generation time but require a more expensive setup.
        Sizes larger than 3 are not recommended. If the relative size is set to
        0, sequential search is used. Default is 1.
    random_state : {None, int, `numpy.random.Generator`,
                    `numpy.random.RandomState`}, optional

        A NumPy random number generator or seed for the underlying NumPy random
        number generator used to generate the stream of uniform random numbers.
        If `random_state` is None (or `np.random`), the `numpy.random.RandomState`
        singleton is used.
        If `random_state` is an int, a new ``RandomState`` instance is used,
        seeded with `random_state`.
        If `random_state` is already a ``Generator`` or ``RandomState`` instance then
        that instance is used.

    Notes
    -----
    This method works when either a finite probability vector is available or
    the PMF of the distribution is available. In case a PMF is only available,
    the *finite* support (domain) of the PMF must also be given. It is
    recommended to first obtain the probability vector by evaluating the PMF
    at each point in the support and then using it instead.

    DGT samples from arbitrary but finite probability vectors. Random numbers
    are generated by the inversion method, i.e.

    1. Generate a random number U ~ U(0,1).
    2. Find smallest integer I such that F(I) = P(X<=I) >= U.

    Step (2) is the crucial step. Using sequential search requires O(E(X))
    comparisons, where E(X) is the expectation of the distribution. Indexed
    search, however, uses a guide table to jump to some I' <= I near I to find
    X in constant time. Indeed the expected number of comparisons is reduced to
    2, when the guide table has the same size as the probability vector
    (this is the default). For larger guide tables this number becomes smaller
    (but is always larger than 1), for smaller tables it becomes larger. For the
    limit case of table size 1 the algorithm simply does sequential search.

    On the other hand the setup time for guide table is O(N), where N denotes
    the length of the probability vector (for size 1 no preprocessing is
    required). Moreover, for very large guide tables memory effects might even
    reduce the speed of the algorithm. So we do not recommend to use guide
    tables that are more than three times larger than the given probability
    vector. If only a few random numbers have to be generated, (much) smaller
    table sizes are better. The size of the guide table relative to the length
    of the given probability vector can be set by the ``guide_factor`` parameter.

    If a probability vector is given, it must be a 1-dimensional array of
    non-negative floats without any ``inf`` or ``nan`` values. Also, there
    must be at least one non-zero entry otherwise an exception is raised.

    By default, the probability vector is indexed starting at 0. However, this
    can be changed by passing a ``domain`` parameter. When ``domain`` is given
    in combination with the PV, it has the effect of relocating the
    distribution from ``(0, len(pv))`` to ``(domain[0], domain[0] + len(pv))``.
    ``domain[1]`` is ignored in this case.

    References
    ----------
    .. [1] UNU.RAN reference manual, Section 5.8.4,
           "DGT - (Discrete) Guide Table method (indexed search)"
           https://statmath.wu.ac.at/unuran/doc/unuran.html#DGT

    .. [2] H.C. Chen and Y. Asau (1974). On generating random variates from an
           empirical distribution, AIIE Trans. 6, pp. 163-166.


    Examples
    --------
    >>> from scipy.stats.sampling import DiscreteGuideTable
    >>> import numpy as np

    To create a random number generator using a probability vector, use:

    >>> pv = [0.1, 0.3, 0.6]
    >>> urng = np.random.default_rng()
    >>> rng = DiscreteGuideTable(pv, random_state=urng)

    The RNG has been setup. Now, we can now use the `rvs` method to
    generate samples from the distribution:

    >>> rvs = rng.rvs(size=1000)

    To verify that the random variates follow the given distribution, we can
    use the chi-squared test (as a measure of goodness-of-fit):

    >>> from scipy.stats import chisquare
    >>> _, freqs = np.unique(rvs, return_counts=True)
    >>> freqs = freqs / np.sum(freqs)
    >>> freqs
    array([0.092, 0.355, 0.553])
    >>> chisquare(freqs, pv).pvalue
    0.9987382966178464

    As the p-value is very high, we fail to reject the null hypothesis that
    the observed frequencies are the same as the expected frequencies. Hence,
    we can safely assume that the variates have been generated from the given
    distribution. Note that this just gives the correctness of the algorithm
    and not the quality of the samples.

    If a PV is not available, an instance of a class with a PMF method and a
    finite domain can also be passed.

    >>> urng = np.random.default_rng()
    >>> from scipy.stats import binom
    >>> n, p = 10, 0.2
    >>> dist = binom(n, p)
    >>> rng = DiscreteGuideTable(dist, random_state=urng)

    Now, we can sample from the distribution using the `rvs` method
    and also measure the goodness-of-fit of the samples:

    >>> rvs = rng.rvs(1000)
    >>> _, freqs = np.unique(rvs, return_counts=True)
    >>> freqs = freqs / np.sum(freqs)
    >>> obs_freqs = np.zeros(11)  # some frequencies may be zero.
    >>> obs_freqs[:freqs.size] = freqs
    >>> pv = [dist.pmf(i) for i in range(0, 11)]
    >>> pv = np.asarray(pv) / np.sum(pv)
    >>> chisquare(obs_freqs, pv).pvalue
    0.9999999999999989

    To check that the samples have been drawn from the correct distribution,
    we can visualize the histogram of the samples:

    >>> import matplotlib.pyplot as plt
    >>> rvs = rng.rvs(1000)
    >>> fig = plt.figure()
    >>> ax = fig.add_subplot(111)
    >>> x = np.arange(0, n+1)
    >>> fx = dist.pmf(x)
    >>> fx = fx / fx.sum()
    >>> ax.plot(x, fx, 'bo', label='true distribution')
    >>> ax.vlines(x, 0, fx, lw=2)
    >>> ax.hist(rvs, bins=np.r_[x, n+1]-0.5, density=True, alpha=0.5,
    ...         color='r', label='samples')
    >>> ax.set_xlabel('x')
    >>> ax.set_ylabel('PMF(x)')
    >>> ax.set_title('Discrete Guide Table Samples')
    >>> plt.legend()
    >>> plt.show()

    To set the size of the guide table use the `guide_factor` keyword argument.
    This sets the size of the guide table relative to the probability vector

    >>> rng = DiscreteGuideTable(pv, guide_factor=1, random_state=urng)

    To calculate the PPF of a binomial distribution with :math:`n=4` and
    :math:`p=0.1`: we can set up a guide table as follows:

    >>> n, p = 4, 0.1
    >>> dist = binom(n, p)
    >>> rng = DiscreteGuideTable(dist, random_state=42)
    >>> rng.ppf(0.5)
    0.0
    """
    cdef double[::1] pv_view
    cdef object domain

    def __cinit__(self,
                  dist,
                  *,
                  domain=None,
                  guide_factor=1,
                  random_state=None):

        cdef double[::1] pv_view

        (pv_view, domain) = self._validate_args(dist, domain, guide_factor)
        self.domain = domain

        # increment ref count of pv_view to make sure it doesn't get garbage collected.
        self.pv_view = pv_view

        # save all the arguments for pickling support
        self._kwargs = {
            'dist': dist,
            'domain': domain,
            'guide_factor': guide_factor,
            'random_state': random_state
        }

        cdef:
            unur_distr *distr
            unur_par *par
            unur_gen *rng

        self._messages = MessageStream()
        _lock.acquire()

        try:
            unur_set_stream(self._messages.handle)

            self.distr = unur_distr_discr_new()

            if self.distr == NULL:
                raise UNURANError(self._messages.get())

            n_pv = len(pv_view)
            self._check_errorcode(unur_distr_discr_set_pv(self.distr, &pv_view[0], n_pv))

            if domain is not None:
                self._check_errorcode(unur_distr_discr_set_domain(self.distr, domain[0], domain[1]))

            self.par = unur_dgt_new(self.distr)
            if self.par == NULL:
                raise UNURANError(self._messages.get())

            self._check_errorcode(unur_dgt_set_guidefactor(self.par, guide_factor))
            self._set_rng(random_state)
        finally:
            _lock.release()

    cdef object _validate_args(self, dist, domain, guide_factor):
        cdef double[::1] pv_view

        domain = _validate_domain(domain, dist)
        if domain is not None:
            if not np.isfinite(domain).all():
                raise ValueError("`domain` must be finite.")
        else:
            if hasattr(dist, 'pmf'):
                raise ValueError("`domain` must be provided when the "
                                 "probability vector is not available.")

        if guide_factor > 3:
            msg = "guide_factor sizes larger than 3 are not recommended."
            warnings.warn(msg, RuntimeWarning)

        if guide_factor == 0:
            msg = ("If the relative size (guide_factor) is set to 0, "
                   "sequential search is used. However, this is not "
                   "recommended, except in exceptional cases, since the "
                   "discrete sequential search method has almost no setup and "
                   "is thus faster.")
            warnings.warn(msg, RuntimeWarning)

        if hasattr(dist, 'pmf'):
            # we assume the PMF accepts and return floats. So, we need
            # to vectorize it to call with an array of points in the domain.
            pmf = np.vectorize(dist.pmf)
            k = np.arange(domain[0], domain[1]+1)
            pv = pmf(k)
            try:
                pv_view = _validate_pv(pv)
            except ValueError as err:
                msg = "PMF returned invalid values: " + err.args[0]
                raise ValueError(msg) from None
        else:
            pv_view = _validate_pv(dist)

        return pv_view, domain

    @cython.boundscheck(False)
    @cython.wraparound(False)
    cdef inline void _ppf(self, const double *u, double *out, size_t N):
        cdef:
            size_t i
        for i in range(N):
            out[i] = unur_dgt_eval_invcdf(self.rng, u[i])

    def ppf(self, u):
        """
        ppf(u)

        PPF of the given distribution.

        Parameters
        ----------
        u : array_like
            Quantiles.

        Returns
        -------
        ppf : array_like
            Percentiles corresponding to given quantiles `u`.
        """
        u = np.asarray(u, dtype='d')
        oshape = u.shape
        u = u.ravel()

        # UNU.RAN fills in ends of the support when u < 0 or u > 1 while
        # SciPy fills in nans. Prefer SciPy behaviour.
        cond0 = 0 <= u
        cond1 = u <= 1
        cond2 = cond0 & cond1
        goodu = argsreduce(cond2, u)[0]
        out = np.empty_like(u)

        cdef double[::1] u_view = np.ascontiguousarray(goodu)
        cdef double[::1] goodout = np.empty_like(u_view)

        if cond2.any():
            self._ppf(&u_view[0], &goodout[0], len(goodu))
        np.place(out, cond2, goodout)
        np.place(out, ~cond2, np.nan)

        # UNU.RAN sets boundary at u = 0 to domain[0]
        # SciPy fills it with domain[0] - 1. Prefer SciPy behaviour
        if self.domain is not None:
            np.place(out, u == 0, self.domain[0] - 1)
        else:
            # domain starts at 0. So, fill in -1.
            np.place(out, u == 0, -1)
        return np.asarray(out).reshape(oshape)[()]
