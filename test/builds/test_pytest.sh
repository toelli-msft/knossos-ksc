set -e

echo Installing dependencies...
python3 -m pip install -r src/python/requirements.txt -f https://download.pytorch.org/whl/torch_stable.html
python3 -m pip install pytest numpy torch==1.9.0+cu111 jax==0.1.57 jaxlib==0.1.41 -f https://download.pytorch.org/whl/torch_stable.html

echo Running pytest '(+ doctest)'
python3 -m pytest test/python --doctest-modules src/python/ksc/path.py

echo Running pytest on ts2k
python3 -m pytest test/ts2k

echo Running pytest using cpp backend
python3 -m pytest test/python/test_tracing_core.py --backend cpp
